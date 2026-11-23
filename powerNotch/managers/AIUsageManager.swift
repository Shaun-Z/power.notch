//
//  AIUsageManager.swift
//  powerNotch
//
//  Descriptor & Strategy Pipeline for AI provider quota, rate limits, and credit balance monitoring.
//  Combines OpenCode (/usage OAuth + local opencode.db cost history), CodexBar, and paseo-usage-monitor strategies.
//

import Combine
import Darwin
import Defaults
import Foundation
import SQLite3
import SwiftUI

@MainActor
final class AIUsageManager: ObservableObject {
    static let shared = AIUsageManager()

    @Published private(set) var snapshots: [AIProviderID: AIProviderSnapshot] = [:]
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var refreshingProviders: Set<AIProviderID> = []
    @Published private(set) var lastGlobalRefresh: Date?
    @Published var providerConfigs: [AIProviderID: AIProviderConfig] = [:]

    // GitHub Copilot Device Flow state
    @Published var copilotDeviceUserCode: String?
    @Published var copilotDeviceVerificationURI: URL?
    @Published var isCopilotDeviceFlowRunning: Bool = false
    private var copilotDeviceFlowTask: Task<Void, Never>?

    private var refreshTimerTask: Task<Void, Never>?
    private var historyCollectionTask: Task<Void, Never>?
    private var cachedDailyHistories: [AIProviderID: [AIUsageWidgetDailyPoint]] = [:]
    private var lastHistoryCollectionAt: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Returns the real user home directory (`/Users/<username>`) even when running inside App Sandbox.
    nonisolated static var realUserHomePath: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return path
            }
        }
        let rawHome = FileManager.default.homeDirectoryForCurrentUser.path
        if let range = rawHome.range(of: "/Library/Containers/") {
            return String(rawHome[..<range.lowerBound])
        }
        return rawHome
    }

    private init() {
        loadProviderConfigs()
        loadCachedSnapshots()
        observeSettingsChanges()
        observeWidgetRefreshRequests()
        schedulePeriodicRefresh()
        syncWidgetSnapshot()
        refresh30DayHistoriesAndSync(force: true)

        Task {
            try? await Task.sleep(for: .seconds(0.8))
            await refreshAllEnabled(userInitiated: false)
        }
    }

    // MARK: - Enabled Providers & Config Persistence

    var enabledProviders: [AIProviderID] {
        let rawList = Defaults[.aiUsageEnabledProviders]
        return AIProviderID.allCases.filter { rawList.contains($0.rawValue) }
    }

    static func pinnedRingKey(provider: AIProviderID, groupID: String) -> String {
        "\(provider.rawValue)|\(groupID)"
    }

    func resolvedPinnedRing(pinnedID: String) -> (provider: AIProviderID, group: AIUsageRingGroup)? {
        if !pinnedID.isEmpty {
            let parts = pinnedID.split(separator: "|", maxSplits: 1)
            if parts.count == 2,
               let provider = AIProviderID(rawValue: String(parts[0])),
               enabledProviders.contains(provider),
               let windows = snapshots[provider]?.windows, !windows.isEmpty
            {
                let groupID = String(parts[1])
                let groups = AIUsageRingGroup.build(from: windows)
                if let matched = groups.first(where: { $0.id == groupID }) {
                    return (provider, matched)
                }
                if let first = groups.first {
                    return (provider, first)
                }
            }
        }

        for provider in enabledProviders {
            if let windows = snapshots[provider]?.windows, !windows.isEmpty,
               let first = AIUsageRingGroup.build(from: windows).first
            {
                return (provider, first)
            }
        }
        return nil
    }

    func isProviderEnabled(_ provider: AIProviderID) -> Bool {
        Defaults[.aiUsageEnabledProviders].contains(provider.rawValue)
    }

    func setProviderEnabled(_ provider: AIProviderID, enabled: Bool) {
        var current = Defaults[.aiUsageEnabledProviders]
        if enabled {
            if !current.contains(provider.rawValue) {
                current.append(provider.rawValue)
            }
        } else {
            current.removeAll { $0 == provider.rawValue }
        }
        Defaults[.aiUsageEnabledProviders] = current
        syncWidgetSnapshot()
        if enabled {
            Task {
                await refresh(provider: provider, userInitiated: true)
            }
        }
    }

    func config(for provider: AIProviderID) -> AIProviderConfig {
        providerConfigs[provider] ?? AIProviderConfig(provider: provider)
    }

    func updateConfig(_ config: AIProviderConfig) {
        providerConfigs[config.provider] = config
        saveProviderConfigs()
    }

    private func loadProviderConfigs() {
        var loaded: [AIProviderID: AIProviderConfig] = [:]
        if let data = Defaults[.aiUsageProviderConfigsData],
           let decoded = try? JSONDecoder().decode([AIProviderID: AIProviderConfig].self, from: data)
        {
            loaded = decoded
        }
        for provider in AIProviderID.allCases where loaded[provider] == nil {
            loaded[provider] = AIProviderConfig(provider: provider)
        }
        self.providerConfigs = loaded
    }

    private func saveProviderConfigs() {
        if let data = try? JSONEncoder().encode(providerConfigs) {
            Defaults[.aiUsageProviderConfigsData] = data
        }
    }

    private func loadCachedSnapshots() {
        guard let data = Defaults[.aiUsageCachedSnapshotsData],
              let decoded = try? JSONDecoder().decode([AIProviderID: AIProviderSnapshot].self, from: data)
        else { return }
        self.snapshots = decoded
    }

    private func saveCachedSnapshots() {
        if let data = try? JSONEncoder().encode(snapshots) {
            Defaults[.aiUsageCachedSnapshotsData] = data
        }
        syncWidgetSnapshot()
        refresh30DayHistoriesAndSync(force: true)
    }

    func syncWidgetSnapshot() {
        AIUsageWidgetSync.sync(
            enabledProviders: enabledProviders,
            snapshots: snapshots,
            dailyHistories: cachedDailyHistories,
            showRemainingPercent: Defaults[.aiUsageShowRemainingPercent],
            hideAccountEmails: Defaults[.aiUsageHideAccountEmails]
        )
    }

    func refresh30DayHistoriesAndSync(force: Bool = false) {
        let activeProviders = enabledProviders
        guard !activeProviders.isEmpty else { return }

        if !force,
           let lastRun = lastHistoryCollectionAt,
           Date().timeIntervalSince(lastRun) < 15,
           activeProviders.allSatisfy({ cachedDailyHistories[$0] != nil })
        {
            return
        }

        let snapshotsCopy = snapshots
        let homePath = Self.realUserHomePath

        historyCollectionTask?.cancel()
        historyCollectionTask = Task.detached(priority: .utility) { [weak self] in
            AIUsageHistoryCollector.recordLedgerObservation(snapshots: snapshotsCopy)
            let histories = AIUsageHistoryCollector.collect30DayHistories(
                for: activeProviders,
                snapshots: snapshotsCopy,
                realUserHomePath: homePath
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedDailyHistories = histories
                self.lastHistoryCollectionAt = Date()
                self.syncWidgetSnapshot()
            }
        }
    }

    private func observeWidgetRefreshRequests() {
        DistributedNotificationCenter.default()
            .publisher(for: AIUsageWidgetBridgeConstants.refreshRequestNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshAllEnabled(userInitiated: false)
                }
            }
            .store(in: &cancellables)
    }

    private func observeSettingsChanges() {
        Defaults.publisher(.aiUsageRefreshInterval)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePeriodicRefresh()
            }
            .store(in: &cancellables)

        Defaults.publisher(.aiUsageShowRemainingPercent, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncWidgetSnapshot()
            }
            .store(in: &cancellables)

        Defaults.publisher(.aiUsageHideAccountEmails, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncWidgetSnapshot()
            }
            .store(in: &cancellables)

        Defaults.publisher(.aiUsageEnabledProviders, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncWidgetSnapshot()
                self?.refresh30DayHistoriesAndSync(force: false)
            }
            .store(in: &cancellables)
    }

    private func schedulePeriodicRefresh() {
        refreshTimerTask?.cancel()
        refreshTimerTask = nil

        let intervalSeconds = Defaults[.aiUsageRefreshInterval]
        guard intervalSeconds > 0 else { return }

        refreshTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled, let self else { return }
                await self.refreshAllEnabled(userInitiated: false)
            }
        }
    }

    // MARK: - Auto-Detection of Local Credentials

    /// Scans known local credential locations and enables providers that have credentials or API keys present.
    func autoDetectLocalProviders() async {
        var detected: Set<String> = Set(Defaults[.aiUsageEnabledProviders])
        for provider in AIProviderID.allCases {
            if hasLocalCredentialAvailable(for: provider) {
                detected.insert(provider.rawValue)
            }
        }
        Defaults[.aiUsageEnabledProviders] = AIProviderID.allCases
            .map(\.rawValue)
            .filter { detected.contains($0) }
        await refreshAllEnabled(userInitiated: true)
    }

    func hasLocalCredentialAvailable(for provider: AIProviderID) -> Bool {
        if AIUsageKeychainStore.readSecret(for: provider) != nil {
            return true
        }
        switch provider {
        case .codex:
            return Self.resolveCodexAccessToken() != nil
        case .claude:
            return Self.resolveClaudeCredential(allowKeychain: false) != nil
        case .antigravity:
            return Self.hasLocalAntigravityInstallation()
        case .copilot:
            return Self.resolveCopilotToken() != nil
        case .cursor:
            return Self.resolveCursorToken() != nil
        case .opencode:
            return Self.resolveOpenCodeAPIKey() != nil || FileManager.default.fileExists(atPath: Self.openCodeDatabasePath)
        case .mimo:
            return Self.resolveMiMoAPIKey() != nil
        case .openrouter:
            return Self.resolveOpenRouterAPIKey() != nil
        case .deepseek:
            return Self.resolveDeepSeekAPIKey() != nil
        case .zai:
            return Self.resolveZaiAPIKey(region: config(for: .zai).region) != nil
        case .kimi:
            return Self.resolveKimiCredential() != nil
        }
    }

    // MARK: - Refresh Orchestration

    func refreshAllEnabled(userInitiated: Bool = false) async {
        let activeProviders = enabledProviders
        guard !activeProviders.isEmpty else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastGlobalRefresh = Date()
            saveCachedSnapshots()
        }

        await withTaskGroup(of: (AIProviderID, AIProviderSnapshot).self) { group in
            for provider in activeProviders {
                refreshingProviders.insert(provider)
                let cfg = config(for: provider)
                let allowKeychain = userInitiated && Defaults[.aiUsageAllowExternalKeychain]
                group.addTask {
                    let snap = await Self.fetchProviderSnapshot(
                        provider: provider,
                        config: cfg,
                        allowExternalKeychain: allowKeychain
                    )
                    return (provider, snap)
                }
            }

            for await (provider, snapshot) in group {
                refreshingProviders.remove(provider)
                applySnapshot(snapshot, for: provider)
            }
        }
    }

    func refresh(provider: AIProviderID, userInitiated: Bool = true) async {
        refreshingProviders.insert(provider)
        isRefreshing = true
        defer {
            refreshingProviders.remove(provider)
            isRefreshing = !refreshingProviders.isEmpty
            lastGlobalRefresh = Date()
            saveCachedSnapshots()
        }

        let cfg = config(for: provider)
        let allowKeychain = userInitiated && Defaults[.aiUsageAllowExternalKeychain]
        let snapshot = await Self.fetchProviderSnapshot(
            provider: provider,
            config: cfg,
            allowExternalKeychain: allowKeychain
        )
        applySnapshot(snapshot, for: provider)
    }

    private func applySnapshot(_ newSnapshot: AIProviderSnapshot, for provider: AIProviderID) {
        // Preserve Antigravity live quota rings when `agy-cli` transiently skips (e.g. locked screen)
        if provider == .antigravity,
           newSnapshot.sourceLabel == "local-db",
           newSnapshot.windows.isEmpty,
           let previous = snapshots[provider],
           !previous.windows.isEmpty
        {
            var merged = previous
            if let freshLocal = newSnapshot.accountLabel, !freshLocal.isEmpty {
                merged.accountLabel = freshLocal
            }
            snapshots[provider] = merged
            return
        }

        // Following CodexBar's resilience rule: preserve last known windows/balance on transient error
        if let error = newSnapshot.errorMessage,
           newSnapshot.windows.isEmpty,
           newSnapshot.balance == nil,
           let previous = snapshots[provider],
           (!previous.windows.isEmpty || previous.balance != nil)
        {
            var merged = previous
            merged.errorMessage = error
            snapshots[provider] = merged
        } else {
            snapshots[provider] = newSnapshot
        }
    }

    // MARK: - GitHub Copilot Device Flow Login

    func startCopilotDeviceFlow() {
        copilotDeviceFlowTask?.cancel()
        isCopilotDeviceFlowRunning = true
        copilotDeviceUserCode = nil
        copilotDeviceVerificationURI = nil

        copilotDeviceFlowTask = Task { @MainActor in
            defer {
                isCopilotDeviceFlowRunning = false
            }
            // Official VS Code Copilot GitHub OAuth client ID used by Copilot CLI / OpenCode / CodexBar
            let clientID = "Iv1.b507a08c87ecfe98"
            guard let codeURL = URL(string: "https://github.com/login/device/code") else { return }
            var req = URLRequest(url: codeURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "client_id=\(clientID)&scope=read:user".data(using: .utf8)

            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deviceCode = json["device_code"] as? String,
                  let userCode = json["user_code"] as? String,
                  let verificationURIString = json["verification_uri"] as? String,
                  let verificationURI = URL(string: verificationURIString)
            else {
                return
            }

            let interval = max(5, (json["interval"] as? Int) ?? 5)
            let expiresIn = (json["expires_in"] as? Int) ?? 900
            self.copilotDeviceUserCode = userCode
            self.copilotDeviceVerificationURI = verificationURI
            NSWorkspace.shared.open(verificationURI)

            let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
            guard let tokenURL = URL(string: "https://github.com/login/oauth/access_token") else { return }

            while Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }

                var pollReq = URLRequest(url: tokenURL)
                pollReq.httpMethod = "POST"
                pollReq.setValue("application/json", forHTTPHeaderField: "Accept")
                pollReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                pollReq.httpBody = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(using: .utf8)

                guard let (pollData, _) = try? await URLSession.shared.data(for: pollReq),
                      let pollJSON = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any]
                else { continue }

                if let accessToken = pollJSON["access_token"] as? String, !accessToken.isEmpty {
                    AIUsageKeychainStore.writeSecret(accessToken, for: .copilot)
                    self.copilotDeviceUserCode = nil
                    self.copilotDeviceVerificationURI = nil
                    await self.refresh(provider: .copilot, userInitiated: true)
                    return
                }

                if let err = pollJSON["error"] as? String {
                    if err == "authorization_pending" || err == "slow_down" {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    func cancelCopilotDeviceFlow() {
        copilotDeviceFlowTask?.cancel()
        copilotDeviceFlowTask = nil
        isCopilotDeviceFlowRunning = false
        copilotDeviceUserCode = nil
        copilotDeviceVerificationURI = nil
    }
}

// MARK: - Provider Strategy Implementations

extension AIUsageManager {
    nonisolated static func fetchProviderSnapshot(
        provider: AIProviderID,
        config: AIProviderConfig,
        allowExternalKeychain: Bool
    ) async -> AIProviderSnapshot {
        switch provider {
        case .codex:
            return await fetchCodexUsage(config: config)
        case .claude:
            return await fetchClaudeUsage(config: config, allowExternalKeychain: allowExternalKeychain)
        case .antigravity:
            return await fetchAntigravityUsage(config: config)
        case .copilot:
            return await fetchCopilotUsage(config: config)
        case .cursor:
            return await fetchCursorUsage(config: config)
        case .opencode:
            return await fetchOpenCodeUsage(config: config)
        case .mimo:
            return await fetchMiMoUsage(config: config)
        case .openrouter:
            return await fetchOpenRouterUsage(config: config)
        case .deepseek:
            return await fetchDeepSeekUsage(config: config)
        case .zai:
            return await fetchZaiUsage(config: config)
        case .kimi:
            return await fetchKimiUsage(config: config)
        }
    }

    // MARK: 1. OpenAI Codex (ChatGPT OAuth)

    nonisolated static func resolveCodexAccessToken() -> (token: String, source: String, email: String?, accountId: String?)? {
        if let manual = AIUsageKeychainStore.readSecret(for: .codex) {
            return (manual, "token", nil, nil)
        }
        let home = Self.realUserHomePath
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(home)/.codex"
        let candidatePaths: [(path: String, label: String)] = [
            ("\(codexHome)/auth.json", "codex-oauth"),
            ("\(home)/.config/codex/auth.json", "codex-oauth"),
            ("\(home)/.local/share/opencode/auth.json", "opencode-oauth")
        ]

        for candidate in candidatePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Native ~/.codex/auth.json format (tokens.access_token or top-level access_token)
            if let tokens = json["tokens"] as? [String: Any],
               let accessToken = tokens["access_token"] as? String,
               !accessToken.isEmpty
            {
                let accountId = tokens["account_id"] as? String
                let email = Self.extractEmailFromJWT(tokens["id_token"] as? String ?? accessToken)
                return (accessToken, candidate.label, email, accountId)
            }
            if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                let email = Self.extractEmailFromJWT(json["id_token"] as? String ?? accessToken)
                return (accessToken, candidate.label, email, json["account_id"] as? String)
            }
            // OpenCode ~/.local/share/opencode/auth.json format: { "openai": { "type": "oauth", "access": "..." } }
            if let openai = json["openai"] as? [String: Any],
               let accessToken = (openai["access"] as? String) ?? (openai["access_token"] as? String),
               !accessToken.isEmpty
            {
                let email = Self.extractEmailFromJWT(accessToken)
                return (accessToken, candidate.label, email, openai["accountId"] as? String)
            }
        }
        return nil
    }

    nonisolated private static func resolveCodexBaseURL(customOverride: String) -> String {
        let trimmed = customOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.hasPrefix("https://") {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let home = Self.realUserHomePath
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(home)/.codex"
        let configPath = "\(codexHome)/config.toml"
        if let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                guard !stripped.hasPrefix("#"), stripped.contains("chatgpt_base_url") else { continue }
                let parts = stripped.components(separatedBy: "=")
                guard parts.count >= 2 else { continue }
                var val = parts[1].components(separatedBy: "#")[0]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if val.hasPrefix("https://") {
                    val = val.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return val
                }
            }
        }
        return "https://chatgpt.com/backend-api"
    }

    nonisolated private static func fetchCodexUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let cred = resolveCodexAccessToken() else {
            return AIProviderSnapshot(
                provider: .codex,
                sourceLabel: "oauth",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "No Codex login found (~/.codex/auth.json)",
                updatedAt: Date()
            )
        }

        let base = resolveCodexBaseURL(customOverride: config.customBaseURL)
        let usageURLString = base.hasSuffix("/wham/usage")
            ? base
            : (base.hasSuffix("/backend-api") ? "\(base)/wham/usage" : "\(base)/backend-api/wham/usage")

        guard let url = URL(string: usageURLString) else {
            return errorSnapshot(.codex, source: cred.source, message: "Invalid Codex endpoint URL")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = cred.accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.codex, source: cred.source, message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.codex, source: cred.source, message: "HTTP \(http.statusCode) (run `codex login` if expired)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorSnapshot(.codex, source: cred.source, message: "Invalid JSON response")
            }

            let planType = (json["plan_type"] as? String)?.capitalized
            var windows: [AIUsageRateWindow] = []

            if let rateLimit = json["rate_limit"] as? [String: Any] {
                if let primary = rateLimit["primary_window"] as? [String: Any],
                   let win = parseCodexWindow(primary, id: "codex_5h", defaultLabel: "5-Hour Session")
                {
                    windows.append(win)
                }
                if let secondary = rateLimit["secondary_window"] as? [String: Any],
                   let win = parseCodexWindow(secondary, id: "codex_weekly", defaultLabel: "Weekly Limit")
                {
                    windows.append(win)
                }
            }

            if let extras = json["additional_rate_limits"] as? [[String: Any]] {
                for (idx, extra) in extras.enumerated() {
                    let limitName = (extra["limit_name"] as? String) ?? "Model \(idx + 1)"
                    if let rl = extra["rate_limit"] as? [String: Any],
                       let primary = rl["primary_window"] as? [String: Any],
                       let win = parseCodexWindow(primary, id: "codex_extra_\(idx)", defaultLabel: limitName)
                    {
                        windows.append(win)
                    }
                }
            }

            var balance: AIUsageBalance?
            var statusNote: String?

            if let credits = json["credits"] as? [String: Any] {
                if let balVal = Self.doubleValue(credits["balance"]) {
                    balance = AIUsageBalance(currency: "Credits", remaining: balVal)
                } else if (credits["unlimited"] as? Bool) == true {
                    statusNote = "Unlimited credits"
                }
            }

            if balance == nil,
               let spendControl = json["spend_control"] as? [String: Any],
               let individual = spendControl["individual_limit"] as? [String: Any]
            {
                let limit = Self.doubleValue(individual["limit"]) ?? Self.doubleValue(individual["max_amount"])
                let used = Self.doubleValue(individual["used"]) ?? Self.doubleValue(individual["current_usage"])
                let remaining = Self.doubleValue(individual["remaining"]) ?? ((limit != nil && used != nil) ? max(0, limit! - used!) : nil)
                if let remaining {
                    balance = AIUsageBalance(
                        currency: "Credits",
                        remaining: remaining,
                        usedThisPeriod: used,
                        limit: limit,
                        periodLabel: "Credit limit"
                    )
                }
            }

            // For Education / Business / Enterprise workspaces where `/wham/usage` omits numeric `credits.balance`
            // (returns `has_credits: true, balance: null`), check local synced workspace credit snapshot.
            if balance == nil,
               let credits = json["credits"] as? [String: Any],
               (credits["has_credits"] as? Bool) == true
            {
                let effectiveAccountId = cred.accountId ?? (json["account_id"] as? String) ?? ""
                let effectiveEmail = cred.email ?? (json["email"] as? String) ?? ""
                if let rawLocal = await XPCHelperClient.shared.fetchCodexLocalCreditSnapshot(
                    accountId: effectiveAccountId,
                    email: effectiveEmail
                ),
                   let localData = rawLocal.data(using: .utf8),
                   let localObj = try? JSONSerialization.jsonObject(with: localData) as? [String: Any],
                   let rem = Self.doubleValue(localObj["remaining"])
                {
                    balance = AIUsageBalance(
                        currency: "Credits",
                        remaining: rem,
                        usedThisPeriod: Self.doubleValue(localObj["used"]),
                        limit: Self.doubleValue(localObj["limit"]),
                        periodLabel: localObj["title"] as? String
                    )
                }
            }

            return AIProviderSnapshot(
                provider: .codex,
                sourceLabel: cred.source,
                accountLabel: cred.email,
                planName: planType,
                windows: windows,
                balance: balance,
                statusNote: statusNote,
                errorMessage: windows.isEmpty && balance == nil ? "Connected (no active windows reported)" : nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.codex, source: cred.source, message: error.localizedDescription)
        }
    }

    nonisolated private static func parseCodexWindow(_ dict: [String: Any], id: String, defaultLabel: String) -> AIUsageRateWindow? {
        guard let usedPercent = Self.doubleValue(dict["used_percent"]) else { return nil }
        var resetAt: Date?
        if let resetEpoch = Self.doubleValue(dict["reset_at"]) {
            resetAt = Date(timeIntervalSince1970: resetEpoch)
        } else if let resetAfter = Self.doubleValue(dict["reset_after_seconds"]) {
            resetAt = Date().addingTimeInterval(resetAfter)
        }
        var label = defaultLabel
        if let windowSeconds = Self.doubleValue(dict["limit_window_seconds"]) {
            if windowSeconds >= 2_500_000 {
                label = "Monthly Limit"
            } else if windowSeconds >= 500_000 {
                label = "Weekly Limit"
            } else if windowSeconds > 0 {
                let hours = Int(round(windowSeconds / 3600))
                if hours > 0 && defaultLabel == "5-Hour Session" {
                    label = "\(hours)-Hour Session"
                }
            }
        }
        return AIUsageRateWindow(
            id: id,
            label: label,
            usedPercent: usedPercent,
            detailText: nil,
            resetAt: resetAt
        )
    }

    // MARK: 2. Anthropic Claude (Claude Code OAuth + Admin API)

    nonisolated static func resolveClaudeCredential(allowKeychain: Bool) -> (token: String, source: String, plan: String?)? {
        if let manual = AIUsageKeychainStore.readSecret(for: .claude) {
            let source = manual.hasPrefix("sk-ant-admin") ? "admin-api" : "oauth"
            return (manual, source, nil)
        }
        if let envAdmin = ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_KEY"], !envAdmin.isEmpty {
            return (envAdmin, "admin-api", "Admin")
        }

        let home = Self.realUserHomePath
        let credPaths = [
            "\(home)/.claude/.credentials.json",
            "\(home)/.config/claude/.credentials.json",
            "\(home)/.local/share/opencode/auth.json"
        ]

        for path in credPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let oauth = json["claudeAiOauth"] as? [String: Any],
               let accessToken = oauth["accessToken"] as? String,
               !accessToken.isEmpty
            {
                let tier = (oauth["subscriptionType"] as? String) ?? (oauth["rateLimitTier"] as? String)
                return (accessToken, "claude-oauth", tier?.capitalized)
            }
            if let anthropic = json["anthropic"] as? [String: Any],
               let accessToken = (anthropic["access"] as? String) ?? (anthropic["access_token"] as? String),
               !accessToken.isEmpty
            {
                return (accessToken, "opencode-oauth", nil)
            }
        }

        if let dbKey = resolveOpenCodeDBCredential(integrationIDs: ["anthropic", "claude"]) {
            return (dbKey, "opencode-db", nil)
        }

        if allowKeychain,
           let kcData = AIUsageKeychainStore.readExternalGenericPassword(service: "Claude Code-credentials"),
           let json = try? JSONSerialization.jsonObject(with: kcData) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           let accessToken = oauth["accessToken"] as? String,
           !accessToken.isEmpty
        {
            let tier = (oauth["subscriptionType"] as? String) ?? (oauth["rateLimitTier"] as? String)
            return (accessToken, "keychain-oauth", tier?.capitalized)
        }

        return nil
    }

    nonisolated private static func fetchClaudeUsage(
        config: AIProviderConfig,
        allowExternalKeychain: Bool
    ) async -> AIProviderSnapshot {
        guard let cred = resolveClaudeCredential(allowKeychain: allowExternalKeychain) else {
            return AIProviderSnapshot(
                provider: .claude,
                sourceLabel: "oauth",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "No Claude credentials (~/.claude/.credentials.json or token)",
                updatedAt: Date()
            )
        }

        // OAuth Subscription Quota Endpoint used by Claude Code, OpenCode (#9545), and CodexBar
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return errorSnapshot(.claude, source: cred.source, message: "Invalid Claude endpoint")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.claude, source: cred.source, message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.claude, source: cred.source, message: "HTTP \(http.statusCode) (refresh Claude Code session)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorSnapshot(.claude, source: cred.source, message: "Invalid JSON response")
            }

            let windowSpecs: [(key: String, label: String)] = [
                ("five_hour", "5-Hour Session"),
                ("seven_day", "Weekly All Models"),
                ("seven_day_sonnet", "Weekly Sonnet"),
                ("seven_day_opus", "Weekly Opus"),
                ("seven_day_oauth_apps", "Weekly OAuth Apps")
            ]

            var windows: [AIUsageRateWindow] = []
            for spec in windowSpecs {
                guard let bucket = json[spec.key] as? [String: Any],
                      let utilization = Self.doubleValue(bucket["utilization"])
                else { continue }

                // Anthropic returns utilization either as 0..100 or 0..1 depending on endpoint version
                let percent = utilization <= 1.0 && utilization > 0 ? utilization * 100.0 : utilization
                let resetAt = Self.parseISO8601Date(bucket["resets_at"] as? String)
                windows.append(
                    AIUsageRateWindow(
                        id: "claude_\(spec.key)",
                        label: spec.label,
                        usedPercent: percent,
                        detailText: nil,
                        resetAt: resetAt
                    )
                )
            }

            var extraBalance: AIUsageBalance?
            if let extraUsage = json["extra_usage"] as? [String: Any],
               (extraUsage["is_enabled"] as? Bool) == true
            {
                let usedCredits = Self.doubleValue(extraUsage["used_credits"])
                let monthlyLimit = Self.doubleValue(extraUsage["monthly_limit"])
                let currency = (extraUsage["currency"] as? String) ?? "USD"
                extraBalance = AIUsageBalance(
                    currency: currency,
                    remaining: (monthlyLimit != nil && usedCredits != nil) ? max(0, monthlyLimit! - usedCredits!) : nil,
                    usedThisPeriod: usedCredits,
                    limit: monthlyLimit,
                    periodLabel: "Extra Usage"
                )
            }

            return AIProviderSnapshot(
                provider: .claude,
                sourceLabel: cred.source,
                accountLabel: nil,
                planName: cred.plan ?? "Claude Pro/Max",
                windows: windows,
                balance: extraBalance,
                statusNote: nil,
                errorMessage: windows.isEmpty ? "Connected (no active rate windows)" : nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.claude, source: cred.source, message: error.localizedDescription)
        }
    }

    // MARK: 3. Antigravity (paseo-usage-monitor: agy CLI Probe + Cloud Code API + Local Protobuf DBs)

    nonisolated private static var antigravityConversationDirectories: [String] {
        let home = Self.realUserHomePath
        return [
            "\(home)/.gemini/antigravity/conversations",
            "\(home)/.gemini/antigravity-cli/conversations",
            "\(home)/.gemini/antigravity-acp/conversations",
            "\(home)/Library/Developer/Xcode/CodingAssistant/antigravity/antigravity-acp/conversations"
        ]
    }

    nonisolated static func resolveAntigravityAccessToken() -> String? {
        if let manual = AIUsageKeychainStore.readSecret(for: .antigravity) {
            return manual
        }
        if let env = ProcessInfo.processInfo.environment["ANTIGRAVITY_ACCESS_TOKEN"], !env.isEmpty {
            return env
        }
        return nil
    }

    nonisolated static func hasLocalAntigravityInstallation() -> Bool {
        if resolveAntigravityAccessToken() != nil {
            return true
        }
        let home = Self.realUserHomePath
        let fm = FileManager.default
        let agyBinPaths = [
            "\(home)/.gemini/bin/agy",
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ]
        if agyBinPaths.contains(where: { fm.fileExists(atPath: $0) }) {
            return true
        }
        return antigravityConversationDirectories.contains(where: { fm.fileExists(atPath: $0) })
    }

    nonisolated private static func fetchAntigravityUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        // Gather 5h local conversation activity (fast read-only SQLite + protobuf scan)
        let localStats = scanLocalAntigravityConversations()
        let localActivityLabel: String?
        if let localStats, localStats.requests5h > 0 {
            localActivityLabel = "5h: \(localStats.requests5h) reqs · \(AIUsageBalance.formatAmount(Double(localStats.tokens5h), currency: "TOKENS"))"
        } else {
            localActivityLabel = nil
        }

        // 1. If a manual Google Cloud Code OAuth token is configured, query retrieveUserQuotaSummary directly
        if let token = resolveAntigravityAccessToken() {
            if let directSnap = await fetchAntigravityCloudCodeQuota(
                token: token,
                config: config,
                localActivityLabel: localActivityLabel
            ) {
                return directSnap
            }
        }

        // 2. Primary zero-config probe via non-sandboxed XPC Helper running `agy --print /usage --output-format json`
        if let rawOutput = await XPCHelperClient.shared.runAntigravityUsageProbe(),
           let parsed = parseAntigravityQuotaJSON(
               rawOutput: rawOutput,
               sourceLabel: "agy-cli",
               planName: nil,
               localActivityLabel: localActivityLabel
           )
        {
            return parsed
        }

        // 3. Fallback to local Antigravity conversation SQLite store metrics when CLI probe is unavailable
        if let localStats, (localStats.requests5h > 0 || localStats.activeDatabases > 0) {
            let balance = AIUsageBalance(
                currency: "TOKENS",
                remaining: Double(localStats.tokens5h),
                periodLabel: "5h Local (\(localStats.requests5h) reqs)"
            )
            return AIProviderSnapshot(
                provider: .antigravity,
                sourceLabel: "local-db",
                accountLabel: "\(localStats.requests5h) reqs (5h)",
                planName: "Local Store",
                windows: [],
                balance: balance,
                statusNote: "Live quota unavailable (ensure `agy` CLI is signed in or add OAuth token)",
                errorMessage: nil,
                updatedAt: Date()
            )
        }

        return AIProviderSnapshot(
            provider: .antigravity,
            sourceLabel: "agy-cli",
            accountLabel: nil,
            planName: nil,
            windows: [],
            balance: nil,
            statusNote: nil,
            errorMessage: "Antigravity CLI (`agy`) not found or not signed in",
            updatedAt: Date()
        )
    }

    nonisolated private static func fetchAntigravityCloudCodeQuota(
        token: String,
        config: AIProviderConfig,
        localActivityLabel: String?
    ) async -> AIProviderSnapshot? {
        let customBase = config.customBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hosts = customBase.isEmpty
            ? ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com"]
            : [customBase]

        for host in hosts {
            guard let url = URL(string: "\(host)/v1internal:retrieveUserQuotaSummary") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = Data("{}".utf8)

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8)
            else {
                continue
            }

            let tierName = await fetchAntigravityTier(host: host, token: token)
            if let snapshot = parseAntigravityQuotaJSON(
                rawOutput: text,
                sourceLabel: "cloudcode-api",
                planName: tierName,
                localActivityLabel: localActivityLabel
            ) {
                return snapshot
            }
        }
        return nil
    }

    nonisolated private static func fetchAntigravityTier(host: String, token: String) async -> String? {
        guard let url = URL(string: "\(host)/v1internal:loadCodeAssist") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data("{\"metadata\":{\"pluginType\":\"GEMINI\"}}".utf8)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let paidTier = (json["paidTier"] as? [String: Any])?["id"] as? String
        let currentTier = (json["currentTier"] as? [String: Any])?["id"] as? String
        let rawTier = (json["g1Tier"] as? String) ?? paidTier ?? currentTier
        guard let tier = rawTier?.lowercased() else { return nil }

        if tier.contains("ultra") { return "AI Ultra" }
        if tier.contains("pro") { return "AI Pro" }
        if tier.contains("standard") { return "Standard" }
        if tier.contains("free") { return "Free" }
        return rawTier
    }

    nonisolated private static func parseAntigravityQuotaJSON(
        rawOutput: String,
        sourceLabel: String,
        planName: String?,
        localActivityLabel: String?
    ) -> AIProviderSnapshot? {
        // Strip ECMA-48 CSI ANSI escape sequences before finding JSON payload
        let cleaned = rawOutput.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        guard let firstBrace = cleaned.firstIndex(of: "{"),
              let lastBrace = cleaned.lastIndex(of: "}"),
              firstBrace <= lastBrace
        else {
            return nil
        }

        let jsonSlice = String(cleaned[firstBrace...lastBrace])
        guard let data = jsonSlice.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // Support both `agy --print /usage --output-format json` (`command.data.groups`)
        // and direct Cloud Code API (`groups` / `data.groups` / `quotaGroups`)
        var groups: [[String: Any]]?
        if let command = root["command"] as? [String: Any],
           let cmdData = command["data"] as? [String: Any],
           let g = cmdData["groups"] as? [[String: Any]]
        {
            groups = g
        } else if let g = root["groups"] as? [[String: Any]] {
            groups = g
        } else if let g = root["quotaGroups"] as? [[String: Any]] {
            groups = g
        } else if let dataObj = root["data"] as? [String: Any],
                  let g = dataObj["groups"] as? [[String: Any]]
        {
            groups = g
        }

        var windows: [AIUsageRateWindow] = []

        if let groups {
            for (gIdx, group) in groups.enumerated() {
                let rawGroupName = (group["name"] as? String)
                    ?? (group["displayName"] as? String)
                    ?? "Pool \(gIdx + 1)"
                let shortGroup = shortenAntigravityGroupName(rawGroupName)
                guard let buckets = group["buckets"] as? [[String: Any]] else { continue }

                // Place 5h window ahead of weekly window within each pool for clarity
                let sortedBuckets = buckets.sorted { lhs, rhs in
                    antigravityBucketSortRank(lhs) < antigravityBucketSortRank(rhs)
                }

                for (bIdx, bucket) in sortedBuckets.enumerated() {
                    guard let remainingFraction = Self.doubleValue(
                        bucket["remaining_fraction"] ?? bucket["remainingFraction"]
                    ) else { continue }

                    let usedPercent = min(100.0, max(0.0, (1.0 - remainingFraction) * 100.0))
                    let bucketID = (bucket["id"] as? String) ?? "agy_\(gIdx)_\(bIdx)"
                    let rawWindow = ((bucket["window"] as? String) ?? "").lowercased()
                    let windowSuffix: String
                    switch rawWindow {
                    case "5h": windowSuffix = "5h"
                    case "weekly", "7d": windowSuffix = "Weekly"
                    case "daily", "24h": windowSuffix = "Daily"
                    default:
                        let bucketName = (bucket["name"] as? String) ?? ""
                        if bucketName.localizedCaseInsensitiveContains("five hour") {
                            windowSuffix = "5h"
                        } else if bucketName.localizedCaseInsensitiveContains("weekly") {
                            windowSuffix = "Weekly"
                        } else if !rawWindow.isEmpty {
                            windowSuffix = rawWindow.capitalized
                        } else {
                            windowSuffix = "Quota"
                        }
                    }

                    let resetStr = (bucket["reset_time"] as? String) ?? (bucket["resetTime"] as? String)
                    let resetAt = Self.parseISO8601Date(resetStr)

                    windows.append(
                        AIUsageRateWindow(
                            id: "antigravity_\(bucketID)",
                            label: "\(shortGroup) \(windowSuffix)",
                            usedPercent: usedPercent,
                            detailText: nil,
                            resetAt: resetAt
                        )
                    )
                }
            }
        } else if let buckets = root["buckets"] as? [[String: Any]] {
            for (bIdx, bucket) in buckets.enumerated() {
                guard let remainingFraction = Self.doubleValue(
                    bucket["remaining_fraction"] ?? bucket["remainingFraction"]
                ) else { continue }
                let usedPercent = min(100.0, max(0.0, (1.0 - remainingFraction) * 100.0))
                let label = (bucket["modelId"] as? String)
                    ?? (bucket["name"] as? String)
                    ?? "Quota \(bIdx + 1)"
                let resetStr = (bucket["reset_time"] as? String) ?? (bucket["resetTime"] as? String)
                windows.append(
                    AIUsageRateWindow(
                        id: "antigravity_bucket_\(bIdx)",
                        label: label,
                        usedPercent: usedPercent,
                        detailText: nil,
                        resetAt: Self.parseISO8601Date(resetStr)
                    )
                )
            }
        }

        guard !windows.isEmpty else { return nil }

        return AIProviderSnapshot(
            provider: .antigravity,
            sourceLabel: sourceLabel,
            accountLabel: localActivityLabel,
            planName: planName ?? "Quota Pools",
            windows: windows,
            balance: nil,
            statusNote: nil,
            errorMessage: nil,
            updatedAt: Date()
        )
    }

    nonisolated private static func shortenAntigravityGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("claude") && lower.contains("gpt") {
            return "Claude/GPT"
        }
        if lower == "gemini models" {
            return "Gemini"
        }
        if lower.contains("argon") {
            return "Gemini Argon"
        }
        return name
            .replacingOccurrences(of: " Models", with: "")
            .replacingOccurrences(of: " models", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func antigravityBucketSortRank(_ bucket: [String: Any]) -> Int {
        let w = ((bucket["window"] as? String) ?? "").lowercased()
        if w == "5h" { return 0 }
        if w == "daily" || w == "24h" { return 1 }
        if w == "weekly" || w == "7d" { return 2 }
        return 3
    }

    /// Scans local Antigravity conversation SQLite DBs in read-only mode (skipping stale files)
    /// and decodes protobuf `steps.metadata` blobs for 5-hour request and token volume.
    nonisolated private static func scanLocalAntigravityConversations() -> (requests5h: Int, tokens5h: Int64, activeDatabases: Int)? {
        let fm = FileManager.default
        let nowSec = Int64(Date().timeIntervalSince1970)
        let cutoffSec = nowSec - 5 * 3600
        let cutoffDate = Date(timeIntervalSince1970: TimeInterval(cutoffSec))

        var foundAnyDirectory = false
        var activeDatabases = 0
        var requests5h = 0
        var tokens5h: Int64 = 0

        for dirPath in antigravityConversationDirectories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            foundAnyDirectory = true

            let dirURL = URL(fileURLWithPath: dirPath)
            guard let files = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in files where fileURL.pathExtension == "db" {
                if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mtime = vals.contentModificationDate,
                   mtime < cutoffDate
                {
                    continue
                }

                var db: OpaquePointer?
                guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                      let db
                else { continue }
                defer { sqlite3_close(db) }
                activeDatabases += 1

                let sql = "SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx DESC;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
                defer { sqlite3_finalize(stmt) }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let byteCount = Int(sqlite3_column_bytes(stmt, 0))
                    guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { continue }
                    let blob = Data(bytes: rawPtr, count: byteCount)
                    guard let parsed = parseAntigravityStepMetadata(blob) else { continue }
                    if parsed.timestamp < cutoffSec {
                        break
                    }
                    requests5h += 1
                    tokens5h += parsed.totalTokens
                }
            }
        }

        guard foundAnyDirectory else { return nil }
        return (requests5h, tokens5h, activeDatabases)
    }

    /// Lightweight protobuf wire decoder for Antigravity `steps.metadata` matching `paseo-usage-monitor`:
    /// - field 1 (len-delim): Timestamp `{ field 1: seconds }`
    /// - field 9 (len-delim): Usage `{ field 2: uncachedInput, field 3: output, field 5: cachedInput, field 9 & 10: output parts }`
    nonisolated private static func parseAntigravityStepMetadata(_ data: Data) -> (timestamp: Int64, totalTokens: Int64)? {
        var timestamp: Int64?
        var usageSlice: Data?

        iterateProtobufFields(data) { fieldNumber, wireType, varintValue, bytesValue in
            if fieldNumber == 1, wireType == 2, let tsBytes = bytesValue {
                iterateProtobufFields(tsBytes) { tsField, tsWire, tsVal, _ in
                    if tsField == 1, tsWire == 0, let secs = tsVal {
                        let s = Int64(bitPattern: secs)
                        if s >= 1_600_000_000 && s <= 2_000_000_000 {
                            timestamp = s
                        }
                    }
                }
            } else if fieldNumber == 9, wireType == 2, let uBytes = bytesValue {
                usageSlice = uBytes
            }
        }

        guard let ts = timestamp, let uBytes = usageSlice else { return nil }

        var uncachedInput: UInt64 = 0
        var output: UInt64 = 0
        var cachedInput: UInt64 = 0
        var outPartA: UInt64 = 0
        var outPartB: UInt64 = 0
        var hasPartA = false
        var hasPartB = false

        iterateProtobufFields(uBytes) { fieldNumber, wireType, varintValue, _ in
            guard wireType == 0, let val = varintValue else { return }
            switch fieldNumber {
            case 2: uncachedInput = val
            case 3: output = val
            case 5: cachedInput = val
            case 9:
                outPartA = val
                hasPartA = true
            case 10:
                outPartB = val
                hasPartB = true
            default:
                break
            }
        }

        if (hasPartA || hasPartB), (outPartA &+ outPartB) != output {
            return nil
        }

        let total = uncachedInput &+ cachedInput &+ output
        guard total > 0, total <= UInt64(Int64.max) else { return nil }
        return (ts, Int64(total))
    }

    nonisolated private static func iterateProtobufFields(
        _ data: Data,
        _ body: (_ fieldNumber: UInt64, _ wireType: UInt8, _ varintValue: UInt64?, _ bytesValue: Data?) -> Void
    ) {
        let bytes = [UInt8](data)
        var index = 0
        let count = bytes.count

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < count && shift < 64 {
                let b = bytes[index]
                index += 1
                result |= UInt64(b & 0x7F) << shift
                if (b & 0x80) == 0 {
                    return result
                }
                shift += 7
            }
            return nil
        }

        while index < count {
            guard let tag = readVarint() else { break }
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x07)
            guard fieldNumber > 0 else { break }

            switch wireType {
            case 0:
                guard let val = readVarint() else { return }
                body(fieldNumber, wireType, val, nil)
            case 1:
                guard index + 8 <= count else { return }
                index += 8
            case 2:
                guard let len64 = readVarint(),
                      len64 <= UInt64(count - index)
                else { return }
                let len = Int(len64)
                let slice = Data(bytes[index..<(index + len)])
                index += len
                body(fieldNumber, wireType, nil, slice)
            case 5:
                guard index + 4 <= count else { return }
                index += 4
            default:
                return
            }
        }
    }

    // MARK: 4. GitHub Copilot

    nonisolated static func resolveCopilotToken() -> (token: String, source: String)? {
        if let manual = AIUsageKeychainStore.readSecret(for: .copilot) {
            return (manual, "oauth")
        }
        if let env = ProcessInfo.processInfo.environment["GITHUB_COPILOT_TOKEN"], !env.isEmpty {
            return (env, "env")
        }

        let home = Self.realUserHomePath
        let copilotFiles = [
            "\(home)/.config/github-copilot/apps.json",
            "\(home)/.config/github-copilot/hosts.json"
        ]
        for file in copilotFiles {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (_, val) in dict {
                if let entry = val as? [String: Any],
                   let oauthToken = entry["oauth_token"] as? String,
                   !oauthToken.isEmpty
                {
                    return (oauthToken, "copilot-cli")
                }
            }
        }

        // OpenCode ~/.local/share/opencode/auth.json
        let openCodeAuth = "\(home)/.local/share/opencode/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: openCodeAuth)),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["github-copilot", "copilot"] {
                if let entry = dict[key] as? [String: Any],
                   let token = (entry["refresh"] as? String) ?? (entry["access"] as? String) ?? (entry["oauth_token"] as? String),
                   !token.isEmpty
                {
                    return (token, "opencode-oauth")
                }
            }
        }

        return nil
    }

    nonisolated private static func fetchCopilotUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let cred = resolveCopilotToken() else {
            return AIProviderSnapshot(
                provider: .copilot,
                sourceLabel: "oauth",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "Not signed in (use GitHub Device Login or ~/.config/github-copilot)",
                updatedAt: Date()
            )
        }

        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            return errorSnapshot(.copilot, source: cred.source, message: "Invalid Copilot URL")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("token \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        req.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        req.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.copilot, source: cred.source, message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.copilot, source: cred.source, message: "HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorSnapshot(.copilot, source: cred.source, message: "Invalid JSON response")
            }

            if (json["access_type_sku"] as? String) == "subscription_ended" {
                return errorSnapshot(.copilot, source: cred.source, message: "Copilot subscription ended")
            }

            let plan = (json["copilot_plan"] as? String ?? json["copilotPlan"] as? String)?.capitalized
            let resetDateStr = (json["quota_reset_date"] as? String) ?? (json["quotaResetDate"] as? String)
            let resetDate = Self.parseISO8601Date(resetDateStr) ?? Self.parseYMDDate(resetDateStr)

            var windows: [AIUsageRateWindow] = []
            let snapshotsDict = (json["quota_snapshots"] as? [String: Any]) ?? (json["quotaSnapshots"] as? [String: Any])

            if let snapshotsDict {
                let orderedKeys: [(keys: [String], id: String, title: String)] = [
                    (["premium_interactions", "premiumInteractions"], "copilot_premium", "Premium Requests"),
                    (["chat"], "copilot_chat", "Chat Quota"),
                    (["completions"], "copilot_completions", "Completions")
                ]

                for item in orderedKeys {
                    guard let snap = item.keys.compactMap({ snapshotsDict[$0] as? [String: Any] }).first else { continue }
                    if (snap["unlimited"] as? Bool) == true { continue }

                    var usedPercent: Double?
                    var detailText: String?

                    if let pctRemaining = Self.doubleValue(snap["percent_remaining"] ?? snap["percentRemaining"]) {
                        usedPercent = max(0, min(100, 100.0 - pctRemaining))
                    }
                    if let entitlement = Self.doubleValue(snap["entitlement"]),
                       let remaining = Self.doubleValue(snap["remaining"]),
                       entitlement > 0
                    {
                        let used = max(0, entitlement - remaining)
                        if usedPercent == nil {
                            usedPercent = (used / entitlement) * 100.0
                        }
                        detailText = "\(Int(used)) / \(Int(entitlement))"
                    }

                    if let usedPercent {
                        windows.append(
                            AIUsageRateWindow(
                                id: item.id,
                                label: item.title,
                                usedPercent: usedPercent,
                                detailText: detailText,
                                resetAt: resetDate
                            )
                        )
                    }
                }
            }

            return AIProviderSnapshot(
                provider: .copilot,
                sourceLabel: cred.source,
                accountLabel: json["login"] as? String,
                planName: plan ?? "Copilot",
                windows: windows,
                balance: nil,
                statusNote: windows.isEmpty ? "Unlimited plan active" : nil,
                errorMessage: nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.copilot, source: cred.source, message: error.localizedDescription)
        }
    }

    // MARK: 5. Cursor

    nonisolated static func resolveCursorToken() -> (value: String, isCookieHeader: Bool, source: String)? {
        if let manual = AIUsageKeychainStore.readSecret(for: .cursor) {
            let isCookie = manual.contains("=")
            return (manual, isCookie, isCookie ? "cookie" : "token")
        }

        let home = Self.realUserHomePath
        // 1. Check ~/.config/cursor/auth.json
        let cliAuthPath = "\(home)/.config/cursor/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cliAuthPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["accessToken"] as? String,
           !token.isEmpty
        {
            return (token, false, "cursor-cli")
        }

        // 2. Read Cursor.app globalStorage/state.vscdb (read-only SQLite)
        let dbPath = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        if FileManager.default.fileExists(atPath: dbPath),
           let token = readSQLiteSingleString(
               dbPath: dbPath,
               query: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
           ),
           !token.isEmpty,
           !token.hasPrefix("cursor-safe-storage:")
        {
            return (token, false, "cursor-app")
        }

        return nil
    }

    nonisolated private static func fetchCursorUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let cred = resolveCursorToken() else {
            return AIProviderSnapshot(
                provider: .cursor,
                sourceLabel: "web",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "No Cursor session found (sign in to Cursor.app or paste Cookie header)",
                updatedAt: Date()
            )
        }

        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            return errorSnapshot(.cursor, source: cred.source, message: "Invalid Cursor URL")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        if cred.isCookieHeader {
            req.setValue(cred.value, forHTTPHeaderField: "Cookie")
        } else {
            let sub = Self.extractSubjectFromJWT(cred.value)
            let cookieToken = sub != nil ? "\(sub!)%3A%3A\(cred.value)" : cred.value
            req.setValue("WorkosCursorSessionToken=\(cookieToken)", forHTTPHeaderField: "Cookie")
            req.setValue("Bearer \(cred.value)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.cursor, source: cred.source, message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.cursor, source: cred.source, message: "HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorSnapshot(.cursor, source: cred.source, message: "Invalid JSON")
            }

            let planName = (json["membershipType"] as? String)?.capitalized
            let cycleEnd = Self.parseISO8601Date(json["billingCycleEnd"] as? String)
            var windows: [AIUsageRateWindow] = []
            var balance: AIUsageBalance?

            if let individual = json["individualUsage"] as? [String: Any] {
                if let plan = individual["plan"] as? [String: Any] {
                    let used = Self.doubleValue(plan["used"]) ?? 0
                    let limit = Self.doubleValue(plan["limit"]) ?? 0
                    let pct = Self.doubleValue(plan["totalPercentUsed"])
                        ?? (limit > 0 ? (used / limit) * 100.0 : nil)
                    if let pct {
                        windows.append(
                            AIUsageRateWindow(
                                id: "cursor_plan",
                                label: "Plan Included",
                                usedPercent: pct,
                                detailText: limit > 0 ? String(format: "$%.2f / $%.2f", used / 100.0, limit / 100.0) : nil,
                                resetAt: cycleEnd
                            )
                        )
                    }
                }
                if let onDemand = individual["onDemand"] as? [String: Any],
                   let usedCents = Self.doubleValue(onDemand["used"])
                {
                    let limitCents = Self.doubleValue(onDemand["limit"])
                    balance = AIUsageBalance(
                        currency: "USD",
                        remaining: limitCents != nil ? max(0, (limitCents! - usedCents) / 100.0) : nil,
                        usedThisPeriod: usedCents / 100.0,
                        limit: limitCents != nil ? limitCents! / 100.0 : nil,
                        periodLabel: "On-Demand"
                    )
                }
            }

            return AIProviderSnapshot(
                provider: .cursor,
                sourceLabel: cred.source,
                accountLabel: nil,
                planName: planName ?? "Cursor",
                windows: windows,
                balance: balance,
                statusNote: nil,
                errorMessage: windows.isEmpty && balance == nil ? "Connected (no active usage reported)" : nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.cursor, source: cred.source, message: error.localizedDescription)
        }
    }

    // MARK: 6. OpenCode / OpenCode Go (API + Local SQLite opencode.db)

    nonisolated static var openCodeDatabasePath: String {
        if let custom = ProcessInfo.processInfo.environment["OPENCODE_DB"], !custom.isEmpty {
            return custom
        }
        return "\(Self.realUserHomePath)/.local/share/opencode/opencode.db"
    }

    /// Reads an API key stored in OpenCode's local SQLite `credential` table (e.g. `integration_id = 'xiaomi'`).
    nonisolated static func resolveOpenCodeDBCredential(integrationIDs: [String]) -> String? {
        let dbPath = openCodeDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db
        else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT integration_id, value FROM credential WHERE active = 1 ORDER BY time_updated DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        let targets = Set(integrationIDs.map { $0.lowercased() })
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0),
                  let valCStr = sqlite3_column_text(stmt, 1)
            else { continue }
            let integration = String(cString: idCStr).lowercased()
            guard targets.contains(integration) else { continue }
            let valStr = String(cString: valCStr)
            if let data = valStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let key = (json["key"] as? String) ?? (json["apiKey"] as? String) ?? (json["access"] as? String),
               !key.isEmpty
            {
                return key
            }
        }
        return nil
    }

    nonisolated static func resolveOpenCodeAPIKey() -> String? {
        if let manual = AIUsageKeychainStore.readSecret(for: .opencode) {
            return manual
        }
        if let env = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"], !env.isEmpty {
            return env
        }
        let authPath = "\(Self.realUserHomePath)/.local/share/opencode/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["opencode-go", "opencode"] {
                if let entry = json[key] as? [String: Any],
                   let apiKey = (entry["key"] as? String) ?? (entry["apiKey"] as? String) ?? (entry["access"] as? String),
                   !apiKey.isEmpty
                {
                    return apiKey
                }
            }
        }
        return resolveOpenCodeDBCredential(integrationIDs: ["opencode", "opencode-go"])
    }

    nonisolated private static func fetchOpenCodeUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        // 1. Try OpenCode Go remote API if API key / OAuth token is present
        if let apiKey = resolveOpenCodeAPIKey(), !apiKey.contains("=") {
            if let url = URL(string: "https://opencode.ai/zen/go/v1/usage") {
                var req = URLRequest(url: url, timeoutInterval: 10)
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    let usageRoot = (json["usage"] as? [String: Any]) ?? json
                    var windows: [AIUsageRateWindow] = []
                    let specs: [(keys: [String], id: String, label: String)] = [
                        (["rolling", "rollingUsage", "fiveHour"], "opencode_5h", "5-Hour Rolling"),
                        (["weekly", "weeklyUsage", "week"], "opencode_weekly", "Weekly Limit"),
                        (["monthly", "monthlyUsage", "month"], "opencode_monthly", "Monthly Limit")
                    ]
                    for spec in specs {
                        if let bucket = spec.keys.compactMap({ usageRoot[$0] as? [String: Any] }).first,
                           let pct = Self.doubleValue(bucket["percent"] ?? bucket["usagePercent"])
                        {
                            var resetAt: Date?
                            if let resetSec = Self.doubleValue(bucket["resetInSec"] ?? bucket["reset_in_sec"]) {
                                resetAt = Date().addingTimeInterval(resetSec)
                            }
                            windows.append(
                                AIUsageRateWindow(
                                    id: spec.id,
                                    label: spec.label,
                                    usedPercent: pct,
                                    detailText: nil,
                                    resetAt: resetAt
                                )
                            )
                        }
                    }
                    if !windows.isEmpty {
                        return AIProviderSnapshot(
                            provider: .opencode,
                            sourceLabel: "api",
                            accountLabel: nil,
                            planName: "OpenCode Go",
                            windows: windows,
                            balance: nil,
                            statusNote: nil,
                            errorMessage: nil,
                            updatedAt: Date()
                        )
                    }
                }
            }
        }

        // 2. Local SQLite cost & token scan fallback from ~/.local/share/opencode/opencode.db
        if let localSnap = scanLocalOpenCodeDatabase() {
            return localSnap
        }

        return AIProviderSnapshot(
            provider: .opencode,
            sourceLabel: "local",
            accountLabel: nil,
            planName: nil,
            windows: [],
            balance: nil,
            statusNote: nil,
            errorMessage: "No OpenCode API key or local ~/.local/share/opencode/opencode.db found",
            updatedAt: Date()
        )
    }

    /// Reads local OpenCode SQLite database (`opencode.db`) in read-only mode to aggregate
    /// cost & token usage across `session_message` and `message` tables.
    nonisolated private static func scanLocalOpenCodeDatabase() -> AIProviderSnapshot? {
        let dbPath = openCodeDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db
        else {
            return nil
        }
        defer { sqlite3_close(db) }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let fiveHourAgoMs = nowMs - 5 * 3600 * 1000
        let weekAgoMs = nowMs - 7 * 24 * 3600 * 1000
        let monthAgoMs = nowMs - 30 * 24 * 3600 * 1000

        let candidateQueries = [
            "SELECT time_created, data FROM session_message WHERE time_created >= \(monthAgoMs) ORDER BY time_created DESC LIMIT 5000;",
            "SELECT time_created, data FROM message WHERE time_created >= \(monthAgoMs) ORDER BY time_created DESC LIMIT 5000;"
        ]

        var cost5h: Double = 0
        var cost7d: Double = 0
        var cost30d: Double = 0
        var tokens7d: Double = 0
        var tokens30d: Double = 0
        var messageCount30d: Int = 0
        var matchedTable = false

        for sql in candidateQueries {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
            matchedTable = true
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_int64(stmt, 0)
                guard let cStr = sqlite3_column_text(stmt, 1) else { continue }
                let jsonStr = String(cString: cStr)
                guard let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let msgCost = Self.doubleValue(obj["cost"]) ?? 0
                if msgCost > 0 {
                    cost30d += msgCost
                    if ts >= weekAgoMs { cost7d += msgCost }
                    if ts >= fiveHourAgoMs { cost5h += msgCost }
                }
                if let tokensObj = obj["tokens"] as? [String: Any] {
                    let inputTok = Self.doubleValue(tokensObj["input"]) ?? 0
                    let outputTok = Self.doubleValue(tokensObj["output"]) ?? 0
                    let cacheRead = Self.doubleValue((tokensObj["cache"] as? [String: Any])?["read"]) ?? 0
                    let totalTok = Self.doubleValue(tokensObj["total"]) ?? (inputTok + outputTok + cacheRead)
                    tokens30d += totalTok
                    if ts >= weekAgoMs { tokens7d += totalTok }
                }
                messageCount30d += 1
            }
        }

        guard matchedTable else { return nil }

        // OpenCode Go standard window denominators ($12 / 5h, $30 / 7d) when cost > 0, or token activity bars
        var windows: [AIUsageRateWindow] = []
        if cost30d > 0 {
            windows = [
                AIUsageRateWindow(
                    id: "opencode_local_5h",
                    label: "5h Spend",
                    usedPercent: min(100, (cost5h / 12.0) * 100.0),
                    detailText: String(format: "$%.2f / $12", cost5h),
                    resetAt: nil,
                    isEstimated: true
                ),
                AIUsageRateWindow(
                    id: "opencode_local_7d",
                    label: "7d Spend",
                    usedPercent: min(100, (cost7d / 30.0) * 100.0),
                    detailText: String(format: "$%.2f / $30", cost7d),
                    resetAt: nil,
                    isEstimated: true
                )
            ]
        }

        let balance: AIUsageBalance
        if cost30d > 0 {
            balance = AIUsageBalance(
                currency: "USD",
                remaining: cost30d,
                usedThisPeriod: tokens30d > 0 ? tokens30d : nil,
                limit: nil,
                periodLabel: "\(messageCount30d) events (30d)"
            )
        } else {
            balance = AIUsageBalance(
                currency: "TOKENS",
                remaining: tokens30d,
                usedThisPeriod: nil,
                limit: nil,
                periodLabel: "30d Local (\(messageCount30d) msgs)"
            )
        }

        return AIProviderSnapshot(
            provider: .opencode,
            sourceLabel: "opencode.db",
            accountLabel: "\(messageCount30d) msgs",
            planName: "Local DB",
            windows: windows,
            balance: balance,
            statusNote: nil,
            errorMessage: nil,
            updatedAt: Date()
        )
    }

    // MARK: 7. Xiaomi MiMo (Official OpenAPI: GET https://api.xiaomimimo.com/v1/platform/balance & Token Plan)

    nonisolated static func resolveMiMoAPIKey() -> String? {
        if let manual = AIUsageKeychainStore.readSecret(for: .mimo) {
            return manual
        }
        for envKey in ["MIMO_API_KEY", "XIAOMI_MIMO_API_KEY", "MIMO_TOKEN_PLAN_KEY"] {
            if let val = ProcessInfo.processInfo.environment[envKey], !val.isEmpty {
                return val
            }
        }
        // Auto-read from OpenCode's auth.json or opencode.db `credential` table (`integration_id = 'xiaomi'`)
        let authPath = "\(Self.realUserHomePath)/.local/share/opencode/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["xiaomi", "mimo", "xiaomimimo"] {
                if let entry = json[key] as? [String: Any],
                   let apiKey = (entry["key"] as? String) ?? (entry["apiKey"] as? String) ?? (entry["access"] as? String),
                   !apiKey.isEmpty
                {
                    return apiKey
                }
            }
        }
        if let dbKey = resolveOpenCodeDBCredential(integrationIDs: ["xiaomi", "mimo", "xiaomimimo"]) {
            return dbKey
        }
        return nil
    }

    nonisolated private static func fetchMiMoUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let apiKey = resolveMiMoAPIKey() else {
            return AIProviderSnapshot(
                provider: .mimo,
                sourceLabel: "api",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "Enter Xiaomi MiMo API key (sk-... or tp-...) in Settings",
                updatedAt: Date()
            )
        }

        // Token Plan exclusive API key (`tp-...`) -> GET /v1/platform/token_plan
        if apiKey.hasPrefix("tp-") {
            let cluster: String
            switch config.region {
            case "sgp": cluster = "token-plan-sgp"
            case "ams": cluster = "token-plan-ams"
            default: cluster = "token-plan-cn"
            }
            let base = config.customBaseURL.isEmpty
                ? "https://\(cluster).xiaomimimo.com"
                : config.customBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let urlString = base.hasSuffix("/v1/platform/token_plan") ? base : "\(base)/v1/platform/token_plan"
            guard let url = URL(string: urlString) else {
                return errorSnapshot(.mimo, source: "api", message: "Invalid MiMo Token Plan URL")
            }

            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue(apiKey, forHTTPHeaderField: "api-key")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    return errorSnapshot(.mimo, source: "api", message: "No HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    return errorSnapshot(.mimo, source: "api", message: "HTTP \(http.statusCode)")
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return errorSnapshot(.mimo, source: "api", message: "Invalid JSON")
                }

                let root = (json["data"] as? [String: Any]) ?? json
                let planCode = ((root["plan_code"] as? String) ?? (root["planCode"] as? String) ?? "Token Plan").uppercased()
                var windows: [AIUsageRateWindow] = []
                var balance: AIUsageBalance?

                let periodDict = root["period"] as? [String: Any]
                let endAtStr = (periodDict?["end_at"] as? String) ?? (root["currentPeriodEnd"] as? String)
                let resetDate = Self.parseISO8601Date(endAtStr) ?? Self.parseDateTimeString(endAtStr)

                if let quota = root["quota"] as? [String: Any] {
                    let total = Self.doubleValue(quota["total_credits"]) ?? 0
                    let used = Self.doubleValue(quota["used_credits"]) ?? 0
                    let remaining = Self.doubleValue(quota["remaining_credits"]) ?? max(0, total - used)
                    if total > 0 {
                        let pct = (used / total) * 100.0
                        windows.append(
                            AIUsageRateWindow(
                                id: "mimo_token_plan",
                                label: "Token Plan Quota",
                                usedPercent: pct,
                                detailText: "\(AIUsageBalance.formatAmount(remaining, currency: "CREDITS")) left",
                                resetAt: resetDate
                            )
                        )
                    }
                    balance = AIUsageBalance(
                        currency: "CREDITS",
                        remaining: remaining,
                        usedThisPeriod: used,
                        limit: total > 0 ? total : nil,
                        periodLabel: "Credits"
                    )
                }

                return AIProviderSnapshot(
                    provider: .mimo,
                    sourceLabel: "token-plan-api",
                    accountLabel: nil,
                    planName: "MiMo \(planCode)",
                    windows: windows,
                    balance: balance,
                    statusNote: nil,
                    errorMessage: nil,
                    updatedAt: Date()
                )
            } catch {
                return errorSnapshot(.mimo, source: "token-plan-api", message: error.localizedDescription)
            }
        }

        // Standard Pay-As-You-Go API Key (`sk-...`) -> Official GET https://api.xiaomimimo.com/v1/platform/balance
        let base = config.customBaseURL.isEmpty
            ? "https://api.xiaomimimo.com"
            : config.customBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = base.hasSuffix("/v1/platform/balance") ? base : "\(base)/v1/platform/balance"
        guard let url = URL(string: urlString) else {
            return errorSnapshot(.mimo, source: "api", message: "Invalid MiMo Balance URL")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(apiKey, forHTTPHeaderField: "api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.mimo, source: "api", message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.mimo, source: "api", message: "HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorSnapshot(.mimo, source: "api", message: "Invalid JSON")
            }

            let isAvailable = (json["is_available"] as? Bool) ?? true
            let availabilityNote = isAvailable ? nil : "Account balance unavailable"

            // Pick the balance_infos entry with the largest total_available (per paseo-usage-monitor)
            if let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty,
               let chosen = infos.max(by: { lhs, rhs in
                   let lCash = Self.doubleValue(lhs["cash_balance"]) ?? 0
                   let lGift = Self.doubleValue(lhs["gift_balance"]) ?? 0
                   let lVal = Self.doubleValue(lhs["total_available"]) ?? (lCash + lGift)

                   let rCash = Self.doubleValue(rhs["cash_balance"]) ?? 0
                   let rGift = Self.doubleValue(rhs["gift_balance"]) ?? 0
                   let rVal = Self.doubleValue(rhs["total_available"]) ?? (rCash + rGift)
                   return lVal < rVal
               })
            {
                let currency = (chosen["currency"] as? String) ?? "CNY"
                let cash = Self.doubleValue(chosen["cash_balance"]) ?? 0
                let gift = Self.doubleValue(chosen["gift_balance"]) ?? 0
                let totalAvailable = Self.doubleValue(chosen["total_available"]) ?? (cash + gift)

                let balance = AIUsageBalance(
                    currency: currency,
                    remaining: totalAvailable,
                    granted: gift,
                    toppedUp: cash
                )

                return AIProviderSnapshot(
                    provider: .mimo,
                    sourceLabel: "api",
                    accountLabel: nil,
                    planName: "Pay-As-You-Go",
                    windows: [],
                    balance: balance,
                    statusNote: availabilityNote,
                    errorMessage: nil,
                    updatedAt: Date()
                )
            }

            let dataObj = (json["data"] as? [String: Any]) ?? json
            if let total = Self.doubleValue(dataObj["total_available"] ?? dataObj["balance"] ?? dataObj["total_balance"] ?? dataObj["cashBalance"]) {
                let cash = Self.doubleValue(dataObj["cashBalance"] ?? dataObj["cash_balance"])
                let gift = Self.doubleValue(dataObj["giftBalance"] ?? dataObj["gift_balance"])
                let balance = AIUsageBalance(
                    currency: (dataObj["currency"] as? String) ?? "CNY",
                    remaining: total,
                    granted: gift,
                    toppedUp: cash
                )
                return AIProviderSnapshot(
                    provider: .mimo,
                    sourceLabel: "api",
                    accountLabel: nil,
                    planName: "Pay-As-You-Go",
                    windows: [],
                    balance: balance,
                    statusNote: availabilityNote,
                    errorMessage: nil,
                    updatedAt: Date()
                )
            }

            return errorSnapshot(.mimo, source: "api", message: "Unrecognized MiMo balance response")
        } catch {
            return errorSnapshot(.mimo, source: "api", message: error.localizedDescription)
        }
    }

    // MARK: 8. OpenRouter

    nonisolated static func resolveOpenRouterAPIKey() -> String? {
        if let manual = AIUsageKeychainStore.readSecret(for: .openrouter) {
            return manual
        }
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty {
            return env
        }
        return resolveOpenCodeDBCredential(integrationIDs: ["openrouter"])
    }

    nonisolated private static func fetchOpenRouterUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let apiKey = resolveOpenRouterAPIKey(), !apiKey.isEmpty else {
            return AIProviderSnapshot(
                provider: .openrouter,
                sourceLabel: "api",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "Enter OpenRouter API key in Settings",
                updatedAt: Date()
            )
        }

        let base = config.customBaseURL.isEmpty
            ? "https://openrouter.ai/api/v1"
            : config.customBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var windows: [AIUsageRateWindow] = []
        var balance: AIUsageBalance?
        var keyLabel: String?

        // 1. Credits API (/api/v1/credits)
        if let creditsURL = URL(string: "\(base)/credits") {
            var req = URLRequest(url: creditsURL, timeoutInterval: 10)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let totalCredits = Self.doubleValue(dataObj["total_credits"]),
               let totalUsage = Self.doubleValue(dataObj["total_usage"])
            {
                balance = AIUsageBalance(
                    currency: "USD",
                    remaining: max(0, totalCredits - totalUsage),
                    usedThisPeriod: totalUsage,
                    limit: totalCredits,
                    periodLabel: "Total Used"
                )
            }
        }

        // 2. Current Key API (/api/v1/key)
        if let keyURL = URL(string: "\(base)/key") {
            var req = URLRequest(url: keyURL, timeoutInterval: 10)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any]
            {
                keyLabel = dataObj["label"] as? String
                let usage = Self.doubleValue(dataObj["usage"]) ?? 0
                let usageMonthly = Self.doubleValue(dataObj["usage_monthly"]) ?? usage
                if let limit = Self.doubleValue(dataObj["limit"]), limit > 0 {
                    let remaining = Self.doubleValue(dataObj["limit_remaining"]) ?? max(0, limit - usage)
                    let usedPct = max(0, min(100, ((limit - remaining) / limit) * 100.0))
                    windows.append(
                        AIUsageRateWindow(
                            id: "openrouter_key_limit",
                            label: "Key Cap",
                            usedPercent: usedPct,
                            detailText: String(format: "$%.2f / $%.2f", limit - remaining, limit),
                            resetAt: nil
                        )
                    )
                }
                if balance == nil {
                    balance = AIUsageBalance(
                        currency: "USD",
                        remaining: Self.doubleValue(dataObj["limit_remaining"]),
                        usedThisPeriod: usageMonthly,
                        limit: Self.doubleValue(dataObj["limit"]),
                        periodLabel: "Monthly"
                    )
                }
            }
        }

        guard !windows.isEmpty || balance != nil else {
            return errorSnapshot(.openrouter, source: "api", message: "Failed to fetch OpenRouter credits or key info")
        }

        return AIProviderSnapshot(
            provider: .openrouter,
            sourceLabel: "api",
            accountLabel: keyLabel,
            planName: "Credits",
            windows: windows,
            balance: balance,
            statusNote: nil,
            errorMessage: nil,
            updatedAt: Date()
        )
    }

    // MARK: 9. DeepSeek (Official GET https://api.deepseek.com/user/balance)

    nonisolated static func resolveDeepSeekAPIKey() -> String? {
        if let manual = AIUsageKeychainStore.readSecret(for: .deepseek) {
            return manual
        }
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ProcessInfo.processInfo.environment["DEEPSEEK_KEY"],
           !env.isEmpty
        {
            return env
        }
        let authPath = "\(Self.realUserHomePath)/.local/share/opencode/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = json["deepseek"] as? [String: Any],
           let apiKey = (entry["key"] as? String) ?? (entry["apiKey"] as? String) ?? (entry["access"] as? String),
           !apiKey.isEmpty
        {
            return apiKey
        }
        return resolveOpenCodeDBCredential(integrationIDs: ["deepseek"])
    }

    nonisolated private static func fetchDeepSeekUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let apiKey = resolveDeepSeekAPIKey(), !apiKey.isEmpty else {
            return AIProviderSnapshot(
                provider: .deepseek,
                sourceLabel: "api",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "Enter DeepSeek API key in Settings",
                updatedAt: Date()
            )
        }

        let base = config.customBaseURL.isEmpty
            ? "https://api.deepseek.com"
            : config.customBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = base.hasSuffix("/user/balance") ? base : "\(base)/user/balance"
        guard let url = URL(string: urlString) else {
            return errorSnapshot(.deepseek, source: "api", message: "Invalid DeepSeek URL")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.deepseek, source: "api", message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.deepseek, source: "api", message: "HTTP \(http.statusCode)")
            }
            // DeepSeek returns both USD and CNY entries in non-deterministic order.
            // Preserve and display both USD + CNY simultaneously in deterministic order (USD, CNY, ...).
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = json["balance_infos"] as? [[String: Any]],
                  !infos.isEmpty
            else {
                return errorSnapshot(.deepseek, source: "api", message: "Invalid DeepSeek balance response")
            }

            let currencyRank: (String) -> Int = { code in
                switch code.uppercased() {
                case "USD": return 0
                case "CNY", "RMB": return 1
                default: return 2
                }
            }

            let parsedBalances: [AIUsageCurrencyBalance] = infos.compactMap { entry in
                guard let currency = entry["currency"] as? String, !currency.isEmpty else { return nil }
                let total = Self.doubleValue(entry["total_balance"]) ?? 0
                let granted = Self.doubleValue(entry["granted_balance"])
                let toppedUp = Self.doubleValue(entry["topped_up_balance"])
                return AIUsageCurrencyBalance(
                    currency: currency.uppercased(),
                    remaining: total,
                    granted: granted,
                    toppedUp: toppedUp
                )
            }
            .sorted { lhs, rhs in
                let r1 = currencyRank(lhs.currency)
                let r2 = currencyRank(rhs.currency)
                return r1 != r2 ? r1 < r2 : lhs.currency < rhs.currency
            }

            let nonZeroBalances = parsedBalances.filter { $0.remaining >= 0.005 }
            let visibleBalances = nonZeroBalances.isEmpty ? Array(parsedBalances.prefix(1)) : nonZeroBalances

            guard let primary = visibleBalances.first else {
                return errorSnapshot(.deepseek, source: "api", message: "Invalid DeepSeek balance response")
            }

            let extras = Array(visibleBalances.dropFirst())
            let isAvailable = (json["is_available"] as? Bool) ?? true

            let balance = AIUsageBalance(
                currency: primary.currency,
                remaining: primary.remaining,
                granted: primary.granted,
                toppedUp: primary.toppedUp,
                additionalBalances: extras.isEmpty ? nil : extras
            )

            return AIProviderSnapshot(
                provider: .deepseek,
                sourceLabel: "api",
                accountLabel: nil,
                planName: "API Balance",
                windows: [],
                balance: balance,
                statusNote: isAvailable ? nil : "Account balance unavailable",
                errorMessage: nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.deepseek, source: "api", message: error.localizedDescription)
        }
    }

    // MARK: 10. GLM / z.ai (BigModel Coding Plan)

    nonisolated static func resolveZaiAPIKey(region: String) -> String? {
        if let manual = AIUsageKeychainStore.readSecret(for: .zai) {
            return manual
        }
        let env = ProcessInfo.processInfo.environment
        if let zai = env["Z_AI_API_KEY"], !zai.isEmpty { return zai }
        if region == "cn" {
            for k in ["BIGMODEL_API_KEY", "ZHIPU_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY"] {
                if let val = env[k], !val.isEmpty { return val }
            }
            let home = Self.realUserHomePath
            for file in ["\(home)/.coding-relay/glm-api-key", "\(home)/.config/bigmodel/api_key", "\(home)/.config/zhipu/api_key"] {
                if let content = try? String(contentsOfFile: file, encoding: .utf8) {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return resolveOpenCodeDBCredential(integrationIDs: ["zai", "glm", "zhipu", "bigmodel"])
    }

    nonisolated private static func fetchZaiUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let apiKey = resolveZaiAPIKey(region: config.region), !apiKey.isEmpty else {
            return AIProviderSnapshot(
                provider: .zai,
                sourceLabel: "api",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "Enter GLM / z.ai API key in Settings",
                updatedAt: Date()
            )
        }

        let defaultHost = config.region == "global" ? "https://api.z.ai" : "https://open.bigmodel.cn"
        let host = config.customBaseURL.isEmpty
            ? defaultHost
            : config.customBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = host.contains("/api/") ? host : "\(host)/api/monitor/usage/quota/limit"

        guard let url = URL(string: urlString) else {
            return errorSnapshot(.zai, source: "api", message: "Invalid GLM / z.ai endpoint")
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return errorSnapshot(.zai, source: "api", message: "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorSnapshot(.zai, source: "api", message: "HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return errorSnapshot(.zai, source: "api", message: "Invalid JSON")
            }

            let dataObj = (json["data"] as? [String: Any]) ?? json
            let planName = (dataObj["planName"] as? String)
                ?? (dataObj["plan"] as? String)
                ?? (dataObj["packageName"] as? String)
                ?? "Coding Plan"

            var windows: [AIUsageRateWindow] = []
            if let limits = dataObj["limits"] as? [[String: Any]] {
                for (idx, item) in limits.enumerated() {
                    let type = (item["type"] as? String) ?? ""
                    guard let pct = Self.doubleValue(item["percentage"]) else { continue }
                    let label: String
                    if type == "TIME_LIMIT" {
                        label = "MCP Quota"
                    } else if let unit = item["unit"] as? Int, let num = item["number"] as? Int {
                        label = unit == 3 ? "\(num)h Coding Quota" : (unit == 4 ? "\(num)d Coding Quota" : "Coding Quota")
                    } else {
                        label = idx == 0 ? "5-Hour Quota" : "Weekly Quota"
                    }

                    var resetAt: Date?
                    if let resetMs = Self.doubleValue(item["nextResetTime"]), resetMs > 0 {
                        resetAt = Date(timeIntervalSince1970: resetMs / 1000.0)
                    }

                    windows.append(
                        AIUsageRateWindow(
                            id: "zai_\(idx)",
                            label: label,
                            usedPercent: min(100, max(0, pct)),
                            detailText: nil,
                            resetAt: resetAt
                        )
                    )
                }
            }

            return AIProviderSnapshot(
                provider: .zai,
                sourceLabel: "api",
                accountLabel: nil,
                planName: planName,
                windows: windows,
                balance: nil,
                statusNote: nil,
                errorMessage: windows.isEmpty ? "No Coding Plan limits returned" : nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.zai, source: "api", message: error.localizedDescription)
        }
    }

    // MARK: 11. Kimi (Kimi Code & Moonshot Open Platform)

    nonisolated static func resolveKimiCredential() -> (token: String, source: String)? {
        if let manual = AIUsageKeychainStore.readSecret(for: .kimi) {
            return (manual, "api")
        }
        let env = ProcessInfo.processInfo.environment
        if let k = env["KIMI_CODE_API_KEY"], !k.isEmpty { return (k, "kimi-code-api") }
        if let m = env["MOONSHOT_API_KEY"], !m.isEmpty { return (m, "moonshot-api") }

        let home = Self.realUserHomePath
        let cliPath = "\(home)/.kimi-code/credentials/kimi-code.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cliPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = (json["access_token"] as? String) ?? (json["accessToken"] as? String),
           !token.isEmpty
        {
            return (token, "kimi-cli")
        }
        if let dbKey = resolveOpenCodeDBCredential(integrationIDs: ["kimi", "moonshot"]) {
            return (dbKey, "opencode-db")
        }
        return nil
    }

    nonisolated private static func fetchKimiUsage(config: AIProviderConfig) async -> AIProviderSnapshot {
        guard let cred = resolveKimiCredential() else {
            return AIProviderSnapshot(
                provider: .kimi,
                sourceLabel: "api",
                accountLabel: nil,
                planName: nil,
                windows: [],
                balance: nil,
                statusNote: nil,
                errorMessage: "No Kimi Code CLI login or API key configured",
                updatedAt: Date()
            )
        }

        let isGlobal = config.region == "global"
        let codeBase = isGlobal ? "https://api.kimi.ai/coding/v1/usages" : "https://api.kimi.com/coding/v1/usages"

        // 1. Try Kimi Code `/coding/v1/usages` first
        if let codeURL = URL(string: codeBase) {
            var req = URLRequest(url: codeURL, timeoutInterval: 10)
            req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                var windows: [AIUsageRateWindow] = []
                if let usages = json["usages"] as? [[String: Any]] {
                    for (idx, item) in usages.enumerated() {
                        let title = (item["name"] as? String) ?? (item["type"] as? String) ?? "Window \(idx + 1)"
                        if let ratio = Self.doubleValue(item["ratio"] ?? item["used_ratio"] ?? item["percentage"]) {
                            let pct = ratio <= 1.0 && ratio > 0 ? ratio * 100.0 : ratio
                            let resetAt = Self.parseISO8601Date(item["reset_at"] as? String)
                            windows.append(
                                AIUsageRateWindow(
                                    id: "kimi_\(idx)",
                                    label: title,
                                    usedPercent: pct,
                                    detailText: nil,
                                    resetAt: resetAt
                                )
                            )
                        }
                    }
                }
                if !windows.isEmpty {
                    return AIProviderSnapshot(
                        provider: .kimi,
                        sourceLabel: cred.source,
                        accountLabel: nil,
                        planName: (json["membership"] as? String) ?? "Kimi Code",
                        windows: windows,
                        balance: nil,
                        statusNote: nil,
                        errorMessage: nil,
                        updatedAt: Date()
                    )
                }
            }
        }

        // 2. Fallback to Moonshot Open Platform balance API (`/v1/users/me/balance`)
        let moonshotBase = isGlobal
            ? "https://api.moonshot.ai/v1/users/me/balance"
            : "https://api.moonshot.cn/v1/users/me/balance"
        guard let balanceURL = URL(string: moonshotBase) else {
            return errorSnapshot(.kimi, source: cred.source, message: "Invalid Kimi URL")
        }

        var req = URLRequest(url: balanceURL, timeoutInterval: 10)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return errorSnapshot(.kimi, source: cred.source, message: "HTTP \(code)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let available = Self.doubleValue(dataObj["available_balance"])
            else {
                return errorSnapshot(.kimi, source: cred.source, message: "Invalid Kimi balance payload")
            }

            let cash = Self.doubleValue(dataObj["cash_balance"])
            let voucher = Self.doubleValue(dataObj["voucher_balance"])
            let balance = AIUsageBalance(
                currency: isGlobal ? "USD" : "CNY",
                remaining: available,
                granted: voucher,
                toppedUp: cash
            )

            return AIProviderSnapshot(
                provider: .kimi,
                sourceLabel: "moonshot-api",
                accountLabel: nil,
                planName: "Moonshot API",
                windows: [],
                balance: balance,
                statusNote: nil,
                errorMessage: nil,
                updatedAt: Date()
            )
        } catch {
            return errorSnapshot(.kimi, source: cred.source, message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    nonisolated private static func errorSnapshot(
        _ provider: AIProviderID,
        source: String,
        message: String
    ) -> AIProviderSnapshot {
        AIProviderSnapshot(
            provider: provider,
            sourceLabel: source,
            accountLabel: nil,
            planName: nil,
            windows: [],
            balance: nil,
            statusNote: nil,
            errorMessage: message,
            updatedAt: Date()
        )
    }

    nonisolated private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    nonisolated private static func parseISO8601Date(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }

    nonisolated private static func parseYMDDate(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: str)
    }

    nonisolated private static func parseDateTimeString(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: str)
    }

    nonisolated private static func decodeJWTClaims(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims
    }

    nonisolated private static func extractEmailFromJWT(_ token: String?) -> String? {
        guard let claims = decodeJWTClaims(token) else { return nil }
        if let email = claims["email"] as? String { return email }
        if let profile = claims["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String
        {
            return email
        }
        return nil
    }

    nonisolated private static func extractSubjectFromJWT(_ token: String?) -> String? {
        decodeJWTClaims(token)?["sub"] as? String
    }

    nonisolated private static func readSQLiteSingleString(dbPath: String, query: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db
        else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0)
        else { return nil }
        return String(cString: cStr)
    }
}
