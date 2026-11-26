import Foundation
import Darwin

enum AIUsageCostSource: String, Codable, Sendable {
    case localEstimate
    case balanceDelta
}

struct AIUsageCost: Codable, Sendable, Equatable {
    var amount: Double
    let currency: String
    let source: AIUsageCostSource

    init(amount: Double, currency: String, source: AIUsageCostSource) {
        self.amount = amount.isFinite ? max(0, amount) : 0
        self.currency = Self.normalizedCurrency(currency)
        self.source = source
    }

    static func normalizedCurrency(_ currency: String) -> String {
        switch currency.uppercased() {
        case "RMB", "¥": return "CNY"
        case "$": return "USD"
        case "€": return "EUR"
        case "£": return "GBP"
        default: return currency.uppercased()
        }
    }

    var currencySymbol: String {
        switch currency {
        case "USD": return "$"
        case "CNY": return "¥"
        case "JPY": return "JP¥"
        case "EUR": return "€"
        case "GBP": return "£"
        // Allowances counted in credits/tokens read as a unit, not as a currency code.
        case "CREDITS", "PTS": return "cr "
        case "TOKENS", "TOK": return "tok "
        default: return currency + " "
        }
    }

    var chartCurrencyPrefix: String {
        source == .localEstimate ? "≈" + currencySymbol : currencySymbol
    }

    /// A credit or token allowance is quota, not money. A subscription that also reports an
    /// API-equivalent estimate keeps its money chart; the allowance only wins when the provider
    /// has nothing else to plot.
    static func isCreditUnit(_ currency: String) -> Bool {
        switch normalizedCurrency(currency) {
        case "CREDITS", "PTS", "TOKENS", "TOK": return true
        default: return false
        }
    }
}

struct AIUsageDailyBucket: Sendable {
    var tokens: Int64 = 0
    // Local log scanners report USD API-equivalent estimates only.
    var cost: Double = 0
    var requests: Int = 0
}

struct AIUsageLedgerEntry: Codable, Sendable {
    var tokens: Int64 = 0
    var costs: [AIUsageCost] = []
    var requests: Int = 0
    // Preserve the old number on disk, but never display it with a guessed currency.
    var legacyUnattributedCost: Double?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case tokens, costs, requests
        case legacyUnattributedCost = "cost"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try values.decodeIfPresent(Int64.self, forKey: .tokens) ?? 0
        costs = try values.decodeIfPresent([AIUsageCost].self, forKey: .costs) ?? []
        requests = try values.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        legacyUnattributedCost = try values.decodeIfPresent(Double.self, forKey: .legacyUnattributedCost)
        // Legacy `cost` had no currency or source. It cannot be safely recovered.
    }

    mutating func addBalanceDelta(_ amount: Double, currency: String) {
        guard amount.isFinite, amount > 0 else { return }
        let currency = AIUsageCost.normalizedCurrency(currency)
        if let index = costs.firstIndex(where: { $0.currency == currency && $0.source == .balanceDelta }) {
            costs[index].amount += amount
        } else {
            costs.append(AIUsageCost(amount: amount, currency: currency, source: .balanceDelta))
        }
    }

    /// Before the ledger tracked currency, the very same balance delta was written to a bare
    /// `cost` field. The currency is not in the file, but a provider whose recorded deltas all
    /// share one currency cannot have billed those older days in another one, so they can be
    /// attributed instead of staying blank. With no single currency to point at, the amount stays
    /// unattributed rather than guessed.
    func attributedCosts(legacyCurrency: String?) -> [AIUsageCost] {
        guard costs.isEmpty,
              let legacy = legacyUnattributedCost,
              legacy.isFinite, legacy > 0,
              let currency = legacyCurrency?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currency.isEmpty
        else { return costs }
        return [AIUsageCost(amount: legacy, currency: currency, source: .balanceDelta)]
    }
}

struct AIUsageWidgetDailyPoint: Codable, Identifiable, Sendable, Equatable {
    let dayKey: String
    let tokens: Int64
    let requests: Int
    let costs: [AIUsageCost]
    let selectedCost: AIUsageCost?

    var id: String { dayKey }
    var cost: Double { selectedCost?.amount ?? 0 }

    init(dayKey: String, tokens: Int64, requests: Int, costs: [AIUsageCost], selectedCost: AIUsageCost? = nil) {
        self.dayKey = dayKey
        self.tokens = tokens
        self.requests = requests
        self.costs = costs
        self.selectedCost = selectedCost
    }

    // Convenience for zero scaffolds and explicitly USD sample data in widget previews.
    init(dayKey: String, tokens: Int64, cost: Double, requests: Int) {
        let estimate = AIUsageCost(amount: cost, currency: "USD", source: .localEstimate)
        self.init(dayKey: dayKey, tokens: tokens, requests: requests, costs: [estimate], selectedCost: estimate)
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, tokens, cost, requests, costs, selectedCost
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try values.decode(String.self, forKey: .dayKey)
        tokens = try values.decode(Int64.self, forKey: .tokens)
        requests = try values.decode(Int.self, forKey: .requests)
        costs = try values.decodeIfPresent([AIUsageCost].self, forKey: .costs) ?? []
        selectedCost = try values.decodeIfPresent(AIUsageCost.self, forKey: .selectedCost)
        // Ignore legacy amounts of unknown denomination until the app refreshes the history.
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dayKey, forKey: .dayKey)
        try values.encode(tokens, forKey: .tokens)
        try values.encode(requests, forKey: .requests)
        try values.encode(costs, forKey: .costs)
        try values.encodeIfPresent(selectedCost, forKey: .selectedCost)
        // Keep older widget readers compatible with the selected, consistently denominated series.
        try values.encode(cost, forKey: .cost)
    }

    /// `"11/23"` for a day bucket, `"14:00"` for an hour bucket (`"2026-11-23T14"`).
    var shortDateLabel: String {
        if let separator = dayKey.firstIndex(of: "T") {
            let hour = dayKey[dayKey.index(after: separator)...]
            return "\(hour):00"
        }
        let parts = dayKey.split(separator: "-")
        if parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) {
            return "\(month)/\(day)"
        }
        return dayKey
    }
}

enum AIUsageCostSeries {
    /// Turns the per-day cost entries of one provider into the single spend series a chart plots.
    ///
    /// - The series is *complete*: every bucket gets the best number the account has for it, so a
    ///   wallet that was only sampled while the app ran still shows the days it spent.
    /// - Real wallet movement wins over the usage-log proxy on the same day — a balance drop is
    ///   money that actually left the account, while a token log is an API-equivalent estimate.
    ///   They are never added together.
    /// - A provider that reports a money wallet (MiMo/DeepSeek in CNY, OpenRouter in USD) charts
    ///   in that currency; anything else — typically a USD estimate — is converted into it.
    /// - Without a money wallet, a history in a single currency is plotted as reported, and a
    ///   history that mixes currencies is unified in USD — and only when one of them *is* USD.
    /// - A credit or token allowance is never converted: it is a quota, not money, and it only
    ///   becomes the series when the provider reports no money at all.
    static func select(
        _ points: [AIUsageWidgetDailyPoint],
        preferredCurrency: String?,
        rates: AIUsageCurrencyRates = .fallback
    ) -> [AIUsageWidgetDailyPoint] {
        let costs = points.flatMap(\.costs).filter { $0.amount > 0 }
        let preferred = preferredCurrency.map(AIUsageCost.normalizedCurrency)
        let wallet = preferred.flatMap { AIUsageCost.isCreditUnit($0) ? nil : $0 }

        // Money wins whenever the provider reports any — even when the pinned balance is an
        // allowance measured in credits.
        if let plan = plan(for: costs.filter { !AIUsageCost.isCreditUnit($0.currency) }, wallet: wallet) {
            return series(points, plan: plan, rates: rates) { !AIUsageCost.isCreditUnit($0.currency) }
        }
        if let plan = plan(for: costs.filter { AIUsageCost.isCreditUnit($0.currency) }, wallet: nil) {
            return series(points, plan: plan, rates: rates) { AIUsageCost.isCreditUnit($0.currency) }
        }
        return points.map { point in
            AIUsageWidgetDailyPoint(
                dayKey: point.dayKey, tokens: point.tokens, requests: point.requests,
                costs: point.costs, selectedCost: nil
            )
        }
    }

    private struct Plan {
        var target: String
        var converts: Bool
        /// Source reported for a bucket that has nothing to plot, and the tie-break when a bucket
        /// has no money movement at all.
        var fallbackSource: AIUsageCostSource
    }

    private static func plan(for costs: [AIUsageCost], wallet: String?) -> Plan? {
        guard !costs.isEmpty else { return nil }
        let currencies = Set(costs.map(\.currency)).sorted()
        guard !currencies.isEmpty else { return nil }
        let hasWalletDelta = costs.contains { $0.source == .balanceDelta }
        let fallbackSource: AIUsageCostSource = hasWalletDelta ? .balanceDelta : .localEstimate

        if let wallet {
            return Plan(
                target: wallet,
                converts: currencies.contains { $0 != wallet },
                fallbackSource: fallbackSource
            )
        }
        if currencies.count == 1, let only = currencies.first {
            return Plan(target: only, converts: false, fallbackSource: fallbackSource)
        }
        if currencies.contains("USD") {
            return Plan(target: "USD", converts: true, fallbackSource: fallbackSource)
        }
        return Plan(target: currencies[0], converts: false, fallbackSource: fallbackSource)
    }

    private static func series(
        _ points: [AIUsageWidgetDailyPoint],
        plan: Plan,
        rates: AIUsageCurrencyRates,
        include: (AIUsageCost) -> Bool
    ) -> [AIUsageWidgetDailyPoint] {
        points.map { point in
            var sums: [AIUsageCostSource: Double] = [:]
            for cost in point.costs where cost.amount > 0 && include(cost) {
                let converted: Double?
                if AIUsageCost.normalizedCurrency(cost.currency) == plan.target {
                    converted = cost.amount
                } else if plan.converts {
                    converted = rates.convert(cost.amount, from: cost.currency, to: plan.target)
                } else {
                    converted = nil
                }
                guard let converted, converted.isFinite else { continue }
                sums[cost.source, default: 0] += converted
            }

            // One number per bucket: real money if the wallet moved, otherwise the log proxy.
            let source: AIUsageCostSource
            let amount: Double
            if let delta = sums[.balanceDelta] {
                source = .balanceDelta
                amount = delta
            } else if let estimate = sums[.localEstimate] {
                source = .localEstimate
                amount = estimate
            } else {
                source = plan.fallbackSource
                amount = 0
            }

            return AIUsageWidgetDailyPoint(
                dayKey: point.dayKey,
                tokens: point.tokens,
                requests: point.requests,
                costs: point.costs,
                selectedCost: AIUsageCost(amount: amount, currency: plan.target, source: source)
            )
        }
    }

    private static func rank(_ source: AIUsageCostSource) -> Int {
        switch source {
        case .balanceDelta: return 0
        case .localEstimate: return 1
        }
    }
}

public enum AIUsageWidgetSharedConstants {
    // This directory is the widget's sole read-only sandbox exception. Keep it in
    // sync with PowerNotchWidgetsExtension.entitlements; never store credentials here.
    public static let fallbackDirectory = "Library/Application Support/powerNotch/widget"

    static func realHomeDirectoryURL() -> URL? {
        // Foundation home-directory APIs point into the extension's sandbox.
        // Use a reentrant passwd lookup so app and extension resolve the same home.
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var size = 16_384
        while size <= 1_048_576 {
            var buffer = [CChar](repeating: 0, count: size)
            var home: String?
            let status = buffer.withUnsafeMutableBufferPointer { buffer in
                let status = getpwuid_r(getuid(), &entry, buffer.baseAddress, buffer.count, &result)
                if status == 0, result != nil, let directory = entry.pw_dir {
                    home = String(validatingCString: directory)
                }
                return status
            }
            if status == ERANGE {
                size *= 2
                continue
            }
            guard status == 0, let home, home.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return nil
    }

    static func payloadFileURL(
        groupID: String = appGroupID,
        homeDirectory: URL? = realHomeDirectoryURL(),
        groupContainer: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    ) -> URL? {
        if hasTeamPrefixedAppGroup(groupID), let container = groupContainer(groupID) {
            return container.appendingPathComponent(payloadFileName, isDirectory: false)
        }
        return homeDirectory?
            .appendingPathComponent(fallbackDirectory, isDirectory: true)
            .appendingPathComponent(payloadFileName, isDirectory: false)
    }

    public static func hasTeamPrefixedAppGroup(_ groupID: String = appGroupID) -> Bool {
        let suffix = ".com.powernotch.app"
        return groupID.hasSuffix(suffix) && groupID.count > suffix.count && !groupID.contains("$(")
    }
    public static let currentSchemaVersion = 4
    public static let widgetKind = "com.powernotch.app.aiUsageWidget"
    public static let payloadFileName = "ai-usage-widget-state.json"
    public static let refreshRequestNotification = Notification.Name("com.powernotch.app.aiUsage.requestRefresh")
    public static var appGroupID: String { resolvedAppGroupID() }

    public static func resolvedAppGroupID(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        guard let value = infoDictionary?["PowerNotchAppGroup"] as? String else { return "com.powernotch.app" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? "com.powernotch.app" : trimmed
    }
}

public enum WeblocSerializer {
    public static func data(for url: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }
}

struct AIUsageWidgetPayload: Codable, Sendable {
    let schemaVersion: Int
    let updatedAt: Date
    let showRemainingPercent: Bool
    let hideAccountEmails: Bool
    let providers: [AIUsageWidgetProviderPage]

    init(schemaVersion: Int, updatedAt: Date, showRemainingPercent: Bool, hideAccountEmails: Bool, providers: [AIUsageWidgetProviderPage]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.showRemainingPercent = showRemainingPercent
        self.hideAccountEmails = hideAccountEmails
        self.providers = providers
    }

    private static func makeSampleHistory(
        tokenScale: Double,
        costScale: Double,
        reqScale: Double,
        phase: Double
    ) -> [AIUsageWidgetDailyPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"

        return (0..<30).reversed().enumerated().compactMap { idx, offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let wave = 0.52 + 0.34 * sin(Double(idx) * 0.45 + phase) + 0.16 * cos(Double(idx) * 0.9 - phase)
            let clamped = max(0.08, wave)
            return AIUsageWidgetDailyPoint(
                dayKey: df.string(from: date),
                tokens: Int64((tokenScale * clamped).rounded()),
                cost: (costScale * clamped * 100).rounded() / 100,
                requests: max(1, Int((reqScale * clamped).rounded()))
            )
        }
    }

    static let sample = AIUsageWidgetPayload(
        schemaVersion: AIUsageWidgetSharedConstants.currentSchemaVersion,
        updatedAt: Date(),
        showRemainingPercent: true,
        hideAccountEmails: false,
        providers: [
            AIUsageWidgetProviderPage(
                id: "claude",
                displayName: "Claude",
                shortName: "Claude",
                iconAssetName: "ProviderIcon-claude",
                symbolName: "sparkles",
                accentRed: 0.88,
                accentGreen: 0.52,
                accentBlue: 0.36,
                innerRed: 0.36,
                innerGreen: 0.78,
                innerBlue: 1.0,
                planName: "Max",
                accountLabel: "claude@powernotch.app",
                sourceLabel: "oauth",
                statusNote: nil,
                errorMessage: nil,
                updatedAt: Date(),
                ringGroups: [
                    AIUsageWidgetRingGroup(
                        id: "dual_default",
                        label: "All",
                        outerWindow: AIUsageWidgetWindow(
                            id: "claude_five_hour",
                            label: "5-Hour Session",
                            usedPercent: 34,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(2 * 3600 + 18 * 60),
                            isEstimated: false
                        ),
                        innerWindow: AIUsageWidgetWindow(
                            id: "claude_seven_day",
                            label: "Weekly All Models",
                            usedPercent: 52,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(3 * 86400 + 6 * 3600),
                            isEstimated: false
                        )
                    )
                ],
                balance: nil,
                dailyHistory: makeSampleHistory(tokenScale: 14_500_000, costScale: 4.8, reqScale: 92, phase: 0.4),
                costCurrencySymbol: "$"
            ),
            AIUsageWidgetProviderPage(
                id: "antigravity",
                displayName: "Antigravity",
                shortName: "Antigravity",
                iconAssetName: "ProviderIcon-antigravity",
                symbolName: "atom",
                accentRed: 0.52,
                accentGreen: 0.80,
                accentBlue: 0.09,
                innerRed: 0.36,
                innerGreen: 0.78,
                innerBlue: 1.0,
                planName: "Ultra",
                accountLabel: nil,
                sourceLabel: "agy-cli",
                statusNote: nil,
                errorMessage: nil,
                updatedAt: Date(),
                ringGroups: [
                    AIUsageWidgetRingGroup(
                        id: "dual_claude_gpt",
                        label: "Claude/GPT",
                        outerWindow: AIUsageWidgetWindow(
                            id: "ag_claude_5h",
                            label: "Claude/GPT 5h",
                            usedPercent: 25,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(3 * 3600),
                            isEstimated: false
                        ),
                        innerWindow: AIUsageWidgetWindow(
                            id: "ag_claude_7d",
                            label: "Claude/GPT Weekly",
                            usedPercent: 40,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(4 * 86400),
                            isEstimated: false
                        )
                    ),
                    AIUsageWidgetRingGroup(
                        id: "dual_pro",
                        label: "Pro",
                        outerWindow: AIUsageWidgetWindow(
                            id: "ag_pro_5h",
                            label: "Pro 5h",
                            usedPercent: 18,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(4 * 3600),
                            isEstimated: false
                        ),
                        innerWindow: AIUsageWidgetWindow(
                            id: "ag_pro_7d",
                            label: "Pro Weekly",
                            usedPercent: 30,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(4 * 86400),
                            isEstimated: false
                        )
                    ),
                    AIUsageWidgetRingGroup(
                        id: "dual_flash",
                        label: "Flash",
                        outerWindow: AIUsageWidgetWindow(
                            id: "ag_flash_5h",
                            label: "Flash 5h",
                            usedPercent: 8,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(4 * 3600),
                            isEstimated: false
                        ),
                        innerWindow: AIUsageWidgetWindow(
                            id: "ag_flash_7d",
                            label: "Flash Weekly",
                            usedPercent: 15,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(4 * 86400),
                            isEstimated: false
                        )
                    )
                ],
                balance: nil,
                dailyHistory: makeSampleHistory(tokenScale: 22_000_000, costScale: 6.2, reqScale: 135, phase: 1.5),
                costCurrencySymbol: "$"
            ),
            AIUsageWidgetProviderPage(
                id: "codex",
                displayName: "OpenAI Codex",
                shortName: "Codex",
                iconAssetName: "ProviderIcon-codex",
                symbolName: "terminal.fill",
                accentRed: 0.16,
                accentGreen: 0.78,
                accentBlue: 0.58,
                innerRed: 0.36,
                innerGreen: 0.78,
                innerBlue: 1.0,
                planName: "Plus",
                accountLabel: nil,
                sourceLabel: "oauth",
                statusNote: nil,
                errorMessage: nil,
                updatedAt: Date(),
                ringGroups: [
                    AIUsageWidgetRingGroup(
                        id: "dual_default",
                        label: "All",
                        outerWindow: AIUsageWidgetWindow(
                            id: "codex_5h",
                            label: "5-Hour Session",
                            usedPercent: 22,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(3 * 3600 + 40 * 60),
                            isEstimated: false
                        ),
                        innerWindow: AIUsageWidgetWindow(
                            id: "codex_weekly",
                            label: "Weekly Limit",
                            usedPercent: 41,
                            detailText: nil,
                            resetAt: Date().addingTimeInterval(5 * 86400),
                            isEstimated: false
                        )
                    )
                ],
                balance: nil,
                dailyHistory: makeSampleHistory(tokenScale: 31_000_000, costScale: 5.5, reqScale: 110, phase: 2.3),
                costCurrencySymbol: "$"
            )
        ]
    )
}

struct AIUsageWidgetProviderPage: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let shortName: String
    let iconAssetName: String
    let symbolName: String
    let accentRed: Double
    let accentGreen: Double
    let accentBlue: Double
    let innerRed: Double
    let innerGreen: Double
    let innerBlue: Double
    let planName: String?
    let accountLabel: String?
    let sourceLabel: String?
    let statusNote: String?
    let errorMessage: String?
    let updatedAt: Date?
    let ringGroups: [AIUsageWidgetRingGroup]
    let balance: AIUsageWidgetBalance?
    let dailyHistory: [AIUsageWidgetDailyPoint]
    /// Last 24 hours, bucketed by hour, for the 1-day trend. Wallet balances are sampled per
    /// refresh, so these buckets come from usage logs only.
    let hourlyHistory: [AIUsageWidgetDailyPoint]
    let costCurrencySymbol: String

    init(
        id: String,
        displayName: String,
        shortName: String,
        iconAssetName: String,
        symbolName: String,
        accentRed: Double,
        accentGreen: Double,
        accentBlue: Double,
        innerRed: Double,
        innerGreen: Double,
        innerBlue: Double,
        planName: String?,
        accountLabel: String?,
        sourceLabel: String?,
        statusNote: String?,
        errorMessage: String?,
        updatedAt: Date?,
        ringGroups: [AIUsageWidgetRingGroup],
        balance: AIUsageWidgetBalance?,
        dailyHistory: [AIUsageWidgetDailyPoint] = [],
        hourlyHistory: [AIUsageWidgetDailyPoint] = [],
        costCurrencySymbol: String = "$"
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.iconAssetName = iconAssetName
        self.symbolName = symbolName
        self.accentRed = accentRed
        self.accentGreen = accentGreen
        self.accentBlue = accentBlue
        self.innerRed = innerRed
        self.innerGreen = innerGreen
        self.innerBlue = innerBlue
        self.planName = planName
        self.accountLabel = accountLabel
        self.sourceLabel = sourceLabel
        self.statusNote = statusNote
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
        self.ringGroups = ringGroups
        self.balance = balance
        self.dailyHistory = dailyHistory
        self.hourlyHistory = hourlyHistory
        self.costCurrencySymbol = costCurrencySymbol
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, shortName, iconAssetName, symbolName
        case accentRed, accentGreen, accentBlue
        case innerRed, innerGreen, innerBlue
        case planName, accountLabel, sourceLabel, statusNote, errorMessage, updatedAt
        case ringGroups, balance, dailyHistory, hourlyHistory, costCurrencySymbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        shortName = try c.decode(String.self, forKey: .shortName)
        iconAssetName = try c.decode(String.self, forKey: .iconAssetName)
        symbolName = try c.decode(String.self, forKey: .symbolName)
        accentRed = try c.decode(Double.self, forKey: .accentRed)
        accentGreen = try c.decode(Double.self, forKey: .accentGreen)
        accentBlue = try c.decode(Double.self, forKey: .accentBlue)
        innerRed = try c.decode(Double.self, forKey: .innerRed)
        innerGreen = try c.decode(Double.self, forKey: .innerGreen)
        innerBlue = try c.decode(Double.self, forKey: .innerBlue)
        planName = try c.decodeIfPresent(String.self, forKey: .planName)
        accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel)
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel)
        statusNote = try c.decodeIfPresent(String.self, forKey: .statusNote)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        ringGroups = try c.decode([AIUsageWidgetRingGroup].self, forKey: .ringGroups)
        balance = try c.decodeIfPresent(AIUsageWidgetBalance.self, forKey: .balance)
        dailyHistory = try c.decodeIfPresent([AIUsageWidgetDailyPoint].self, forKey: .dailyHistory) ?? []
        hourlyHistory = try c.decodeIfPresent([AIUsageWidgetDailyPoint].self, forKey: .hourlyHistory) ?? []
        costCurrencySymbol = try c.decodeIfPresent(String.self, forKey: .costCurrencySymbol) ?? "$"
    }

    var allWindows: [AIUsageWidgetWindow] {
        var result: [AIUsageWidgetWindow] = []
        for group in ringGroups {
            result.append(group.outerWindow)
            if let inner = group.innerWindow {
                result.append(inner)
            }
        }
        return result
    }

    var total30dTokens: Int64 {
        dailyHistory.reduce(0) { $0 + max(0, $1.tokens) }
    }

    var total30dCost: Double {
        dailyHistory.reduce(0) { $0 + max(0, $1.cost) }
    }

    var total30dRequests: Int {
        dailyHistory.reduce(0) { $0 + max(0, $1.requests) }
    }
}

struct AIUsageWidgetRingGroup: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let outerWindow: AIUsageWidgetWindow
    let innerWindow: AIUsageWidgetWindow?

    init(id: String, label: String, outerWindow: AIUsageWidgetWindow, innerWindow: AIUsageWidgetWindow?) {
        self.id = id
        self.label = label
        self.outerWindow = outerWindow
        self.innerWindow = innerWindow
    }

    var isDual: Bool { innerWindow != nil }
}

struct AIUsageWidgetWindow: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
    let detailText: String?
    let resetAt: Date?
    let isEstimated: Bool

    init(id: String, label: String, usedPercent: Double, detailText: String?, resetAt: Date?, isEstimated: Bool) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.detailText = detailText
        self.resetAt = resetAt
        self.isEstimated = isEstimated
    }

    var clampedUsedPercent: Double {
        min(100, max(0, usedPercent))
    }

    var remainingPercent: Double {
        max(0, 100 - clampedUsedPercent)
    }

    func displayPercent(showRemaining: Bool) -> Double {
        showRemaining ? remainingPercent : clampedUsedPercent
    }

    func ringProgress(showRemaining: Bool) -> Double {
        displayPercent(showRemaining: showRemaining) / 100.0
    }

    func resetCountdownText(referenceDate: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSince(referenceDate)
        guard remaining > 0 else { return "Resetting" }
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(max(1, minutes))m"
        }
    }
}

struct AIUsageWidgetBalance: Codable, Sendable, Equatable {
    let currency: String
    let remaining: Double?
    let usedThisPeriod: Double?
    let limit: Double?
    let periodLabel: String?
    let formattedRemaining: String
    let compactFormattedRemaining: String
    let formattedBreakdown: String?

    init(currency: String, remaining: Double?, usedThisPeriod: Double?, limit: Double?, periodLabel: String?, formattedRemaining: String, compactFormattedRemaining: String, formattedBreakdown: String?) {
        self.currency = currency
        self.remaining = remaining
        self.usedThisPeriod = usedThisPeriod
        self.limit = limit
        self.periodLabel = periodLabel
        self.formattedRemaining = formattedRemaining
        self.compactFormattedRemaining = compactFormattedRemaining
        self.formattedBreakdown = formattedBreakdown
    }
}
