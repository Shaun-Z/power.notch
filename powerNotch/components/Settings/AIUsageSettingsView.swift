//
//  AIUsageSettingsView.swift
//  powerNotch
//
//  Settings UI for AI Provider Usage & Balance Monitoring (OpenCode + CodexBar + Antigravity + Xiaomi MiMo + DeepSeek).
//

import AppKit
import Defaults
import SwiftUI

struct AIUsageSettingsView: View {
    @ObservedObject private var usageManager = AIUsageManager.shared

    @Default(.enableAIUsageNotchTab) private var enableAIUsageNotchTab
    @Default(.aiUsageRefreshInterval) private var aiUsageRefreshInterval
    @Default(.aiUsageShowRemainingPercent) private var aiUsageShowRemainingPercent
    @Default(.aiUsageHideAccountEmails) private var aiUsageHideAccountEmails
    @Default(.aiUsageAllowExternalKeychain) private var aiUsageAllowExternalKeychain
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    @State private var expandedProvider: AIProviderID?

    var body: some View {
        Form {
            // MARK: - General & Notch Display
            Section {
                Defaults.Toggle(key: .enableAIUsageNotchTab) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show AI Usage tab in expanded Notch")
                        Text("Adds an AI Usage tab in the top-left header of the expanded Notch view.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Auto-refresh interval", selection: $aiUsageRefreshInterval) {
                    Text("Every 1 minute").tag(60)
                    Text("Every 2 minutes").tag(120)
                    Text("Every 5 minutes").tag(300)
                    Text("Every 15 minutes").tag(900)
                    Text("Manual only").tag(0)
                }

                Defaults.Toggle(key: .aiUsageShowRemainingPercent) {
                    Text("Show remaining quota percentage instead of used percentage")
                }

                Defaults.Toggle(key: .aiUsageHideAccountEmails) {
                    Text("Hide account emails and usernames")
                }

                Defaults.Toggle(key: .aiUsageAllowExternalKeychain) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow reading external CLI Keychain items (Claude Code)")
                        Text("Off by default to avoid macOS Keychain prompts. File credentials (`~/.codex`, `~/.claude`, `~/.gemini`, `~/.local/share/opencode`) are read without Keychain prompts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Display & Refresh")
            }

            // MARK: - Live Usage Overview
            Section {
                // Toolbar row inside section so it never overflows the Section header
                HStack(spacing: 8) {
                    if let last = usageManager.lastGlobalRefresh {
                        Label(
                            "Updated \(last.formatted(date: .omitted, time: .shortened))",
                            systemImage: "clock"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Reads local CLI credentials & API balances automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task {
                            await usageManager.autoDetectLocalProviders()
                        }
                    } label: {
                        Label("Auto-Detect Local", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        Task {
                            await usageManager.refreshAllEnabled(userInitiated: true)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if usageManager.isRefreshing {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh All")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(usageManager.isRefreshing)
                }
                .padding(.vertical, 2)

                if usageManager.enabledProviders.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No AI Providers Enabled")
                                .font(.subheadline.weight(.semibold))
                            Text("Enable providers below or click Auto-Detect Local to scan `~/.codex`, `~/.claude`, `~/.gemini`, `~/.local/share/opencode`, Cursor, and Copilot.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(usageManager.enabledProviders) { provider in
                        AIUsageOverviewRow(
                            provider: provider,
                            snapshot: usageManager.snapshots[provider],
                            isRefreshing: usageManager.refreshingProviders.contains(provider),
                            showRemaining: aiUsageShowRemainingPercent,
                            hideEmails: aiUsageHideAccountEmails,
                            onRefresh: {
                                Task {
                                    await usageManager.refresh(provider: provider, userInitiated: true)
                                }
                            },
                            onConfigure: {
                                withAnimation(.snappy(duration: 0.22)) {
                                    expandedProvider = provider
                                }
                            }
                        )
                    }
                }
            } header: {
                Text("Live Usage & Balances")
            }

            // MARK: - Providers Configuration
            Section {
                ForEach(AIProviderID.allCases) { provider in
                    AIProviderConfigurationRow(
                        provider: provider,
                        isExpanded: expandedProvider == provider,
                        onToggleExpand: {
                            withAnimation(.snappy(duration: 0.22)) {
                                expandedProvider = expandedProvider == provider ? nil : provider
                            }
                        }
                    )
                }
            } header: {
                Text("Providers & Credentials")
            } footer: {
                Text("API keys entered manually are stored locally in PowerNotch's sandboxed Application Support container (0600 permissions) without macOS Keychain prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("AI Usage")
        .onAppear {
            if usageManager.lastGlobalRefresh == nil {
                Task {
                    await usageManager.refreshAllEnabled(userInitiated: false)
                }
            }
        }
    }
}

// MARK: - Full-Width Overview Row

private struct AIUsageOverviewRow: View {
    let provider: AIProviderID
    let snapshot: AIProviderSnapshot?
    let isRefreshing: Bool
    let showRemaining: Bool
    let hideEmails: Bool
    let onRefresh: () -> Void
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top bar: Icon + Provider Name + Plan Badge + Account + Actions
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(provider.accentColor.opacity(0.16))
                        .frame(width: 26, height: 26)
                    AIProviderIconView(provider: provider, size: 15)
                        .foregroundStyle(provider.accentColor)
                }

                Text(provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if let plan = snapshot?.planName, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(provider.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(provider.accentColor.opacity(0.14))
                        )
                        .lineLimit(1)
                }

                if let src = snapshot?.sourceLabel, !src.isEmpty {
                    Text(src)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !hideEmails, let acct = snapshot?.accountLabel, !acct.isEmpty {
                    Text("· \(acct)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                // If provider has both windows AND a balance, show compact balance on right
                if let snapshot, !snapshot.windows.isEmpty, let balance = snapshot.balance {
                    Text(balance.formattedRemaining)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh \(provider.displayName)")

                if let url = provider.dashboardURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(provider.displayName) Dashboard")
                }
            }

            // Body: Windows (Concentric/Single Rings + Full Text), Balance, or Error
            if let snapshot {
                if !snapshot.windows.isEmpty {
                    let groups = AIUsageRingGroup.build(from: snapshot.windows)
                    VStack(spacing: 8) {
                        ForEach(groups) { group in
                            ringGroupRow(group)
                        }
                    }
                    if let breakdown = snapshot.balance?.formattedBreakdown {
                        Text(breakdown)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let note = snapshot.statusNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else if let balance = snapshot.balance {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(balance.formattedRemaining)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                        if let secondary = balance.formattedBreakdown {
                            Text(secondary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    if let note = snapshot.statusNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else if let note = snapshot.statusNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let err = snapshot.errorMessage, snapshot.windows.isEmpty && snapshot.balance == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Configure…", action: onConfigure)
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
            } else {
                HStack {
                    Text("Waiting for initial refresh…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh", action: onRefresh)
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func ringGroupRow(_ group: AIUsageRingGroup) -> some View {
        let outerPct = showRemaining ? group.outerWindow.remainingPercent : group.outerWindow.clampedUsedPercent
        let outerColor = provider.outerRingColor(for: group.outerWindow)

        if let inner = group.innerWindow {
            let innerPct = showRemaining ? inner.remainingPercent : inner.clampedUsedPercent
            let innerColor = provider.innerRingColor(for: inner)

            HStack(spacing: 12) {
                AIUsageDualRingGauge(
                    outerProgress: outerPct / 100.0,
                    innerProgress: innerPct / 100.0,
                    outerColor: outerColor,
                    innerColor: innerColor,
                    size: 38,
                    outerLineWidth: 3.4,
                    innerLineWidth: 3.0,
                    ringGap: 2.2,
                    outerTrackColor: Color.primary.opacity(0.11),
                    innerTrackColor: Color.primary.opacity(0.09)
                )

                VStack(alignment: .leading, spacing: 4) {
                    windowTextLine(
                        group.outerWindow,
                        displayPct: outerPct,
                        indicatorColor: outerColor,
                        ringHint: "Outer"
                    )
                    windowTextLine(
                        inner,
                        displayPct: innerPct,
                        indicatorColor: innerColor,
                        ringHint: "Inner"
                    )
                }
            }
        } else {
            HStack(spacing: 12) {
                AIUsageSingleRingGauge(
                    progress: outerPct / 100.0,
                    color: outerColor,
                    centerLabel: String(format: "%.0f%%", outerPct),
                    size: 34,
                    lineWidth: 3.2,
                    trackColor: Color.primary.opacity(0.11),
                    labelColor: .primary
                )

                windowTextLine(
                    group.outerWindow,
                    displayPct: outerPct,
                    indicatorColor: outerColor,
                    ringHint: nil
                )
            }
        }
    }

    @ViewBuilder
    private func windowTextLine(
        _ window: AIUsageRateWindow,
        displayPct: Double,
        indicatorColor: Color,
        ringHint: String?
    ) -> some View {
        HStack(spacing: 6) {
            if ringHint != nil {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
            }

            Text(window.label)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 6)

            if let detail = window.detailText {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let reset = window.resetCountdownText {
                Text("resets in \(reset)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(String(format: "%.0f%% %@", displayPct, showRemaining ? "left" : "used"))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(indicatorColor)
        }
    }
}

// MARK: - Provider Configuration Row

private struct AIProviderConfigurationRow: View {
    let provider: AIProviderID
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @ObservedObject private var usageManager = AIUsageManager.shared
    @State private var secretInput: String = ""
    @State private var hasStoredSecret: Bool = false
    @State private var showPlainSecret: Bool = false

    private var secretPlaceholder: String {
        switch provider {
        case .antigravity: return "Optional Google Cloud Code OAuth access token (ya29....)"
        case .mimo: return "Xiaomi MiMo API Key (sk-... or tp-...)"
        case .openrouter: return "OpenRouter API Key (sk-or-v1-...)"
        case .deepseek: return "DeepSeek API Key (sk-...)"
        case .zai: return "GLM / z.ai API Key"
        case .kimi: return "Kimi Code / Moonshot API Key"
        case .cursor: return "Cursor Cookie header or token"
        case .claude: return "Claude OAuth token or Admin API key"
        case .codex: return "Codex OAuth access token"
        case .copilot: return "GitHub OAuth token (ghu_... / gho_...)"
        case .opencode: return "OpenCode Go API Key"
        }
    }

    var body: some View {
        let isEnabled = usageManager.isProviderEnabled(provider)
        let config = usageManager.config(for: provider)
        let isAutoDetected = usageManager.hasLocalCredentialAvailable(for: provider)

        VStack(alignment: .leading, spacing: 8) {
            // Compact single-line header row that never clips
            HStack(spacing: 8) {
                AIProviderIconView(provider: provider, size: 15)
                    .foregroundStyle(provider.accentColor)
                    .frame(width: 18)

                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if hasStoredSecret {
                    statusBadge(text: "Key Saved", color: .green)
                } else if isAutoDetected {
                    statusBadge(text: "Local Detected", color: .blue)
                }

                Spacer(minLength: 6)

                Button(action: onToggleExpand) {
                    HStack(spacing: 3) {
                        Text(isExpanded ? "Hide" : "Configure")
                            .font(.caption)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { usageManager.setProviderEnabled(provider, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(provider.credentialHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Region selector for MiMo / GLM / Kimi (menu style to prevent horizontal overflow)
                    if provider.supportsRegionSelection {
                        Picker(
                            "Endpoint / Region",
                            selection: Binding(
                                get: { config.region },
                                set: { newRegion in
                                    var updated = config
                                    updated.region = newRegion
                                    usageManager.updateConfig(updated)
                                    Task { await usageManager.refresh(provider: provider, userInitiated: true) }
                                }
                            )
                        ) {
                            ForEach(provider.availableRegions, id: \.id) { item in
                                Text(item.title).tag(item.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }

                    // GitHub Copilot Device Flow Helper
                    if provider == .copilot {
                        copilotDeviceFlowSection
                    }

                    // API Key / Token / Cookie input stored in PowerNotch Keychain
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key / Token Override:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            Group {
                                if showPlainSecret {
                                    TextField(secretPlaceholder, text: $secretInput)
                                } else {
                                    SecureField(secretPlaceholder, text: $secretInput)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                            Button {
                                showPlainSecret.toggle()
                            } label: {
                                Image(systemName: showPlainSecret ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showPlainSecret ? "Hide secret" : "Show secret")

                            Button("Save") {
                                AIUsageKeychainStore.writeSecret(secretInput, for: provider)
                                hasStoredSecret = AIUsageKeychainStore.readSecret(for: provider) != nil
                                Task {
                                    await usageManager.refresh(provider: provider, userInitiated: true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if hasStoredSecret {
                                Button("Clear", role: .destructive) {
                                    secretInput = ""
                                    AIUsageKeychainStore.writeSecret("", for: provider)
                                    hasStoredSecret = false
                                    Task {
                                        await usageManager.refresh(provider: provider, userInitiated: true)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    // Custom Base URL override
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Base URL (Optional):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            "Default official endpoint",
                            text: Binding(
                                get: { config.customBaseURL },
                                set: { newURL in
                                    var updated = config
                                    updated.customBaseURL = newURL
                                    usageManager.updateConfig(updated)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if let existing = AIUsageKeychainStore.readSecret(for: provider) {
                hasStoredSecret = true
                secretInput = existing
            } else {
                hasStoredSecret = false
            }
        }
    }

    @ViewBuilder
    private var copilotDeviceFlowSection: some View {
        HStack(spacing: 8) {
            if usageManager.isCopilotDeviceFlowRunning {
                if let code = usageManager.copilotDeviceUserCode {
                    Text("Code:")
                        .font(.caption)
                    Text(code)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.purple.opacity(0.18))
                        )
                    Button("Copy & Open GitHub") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        if let url = usageManager.copilotDeviceVerificationURI {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Requesting GitHub Device Code…")
                        .font(.caption)
                }

                Button("Cancel") {
                    usageManager.cancelCopilotDeviceFlow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    usageManager.startCopilotDeviceFlow()
                } label: {
                    Label("Sign in with GitHub Device Flow", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
            .fixedSize()
    }
}
