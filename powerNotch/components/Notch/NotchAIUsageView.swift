//
//  NotchAIUsageView.swift
//  powerNotch
//
//  Compact Concentric Ring AI Provider Usage & Balance Dashboard for the Expanded Notch.
//  For model pools with both 5h and weekly limits, renders a dual-ring gauge (outer = 5h, inner = weekly).
//

import Defaults
import SwiftUI

struct NotchAIUsageView: View {
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageHideAccountEmails) private var hideAccountEmails
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw
    @Default(.aiUsagePinnedRingID) private var pinnedRingID

    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: 6),
        GridItem(.flexible(minimum: 120), spacing: 6),
        GridItem(.flexible(minimum: 120), spacing: 6)
    ]

    var body: some View {
        let providers = usageManager.enabledProviders
        VStack(spacing: 4) {
            // Slim top toolbar
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.effectiveAccent)
                    Text("AI Usage")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    if let lastRefreshed = usageManager.lastGlobalRefresh {
                        Text("· \(Self.relativeTimeString(from: lastRefreshed))")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                Spacer()

                // Compact legend for concentric dual rings
                HStack(spacing: 3) {
                    Image(systemName: "circle.circle")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Outer 5h · Inner 7d")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.trailing, 2)

                Button {
                    showRemainingPercent.toggle()
                } label: {
                    Text(showRemainingPercent ? "Left %" : "Used %")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(liquidGlassNotch ? 0.12 : 0.09))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        await usageManager.refreshAllEnabled(userInitiated: true)
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        if usageManager.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.68)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        Text("Refresh")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(liquidGlassNotch ? 0.14 : 0.10))
                    )
                }
                .buttonStyle(.plain)
                .disabled(usageManager.isRefreshing)
            }

            if providers.isEmpty {
                emptyProvidersView
            } else {
                let resolvedPinned = usageManager.resolvedPinnedRing(pinnedID: pinnedRingID)
                let activePinnedKey = resolvedPinned.map {
                    AIUsageManager.pinnedRingKey(provider: $0.provider, groupID: $0.group.id)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(providers) { provider in
                            NotchAIProviderCompactCard(
                                provider: provider,
                                snapshot: usageManager.snapshots[provider],
                                isRefreshing: usageManager.refreshingProviders.contains(provider),
                                isLiquidGlass: liquidGlassNotch,
                                showRemaining: showRemainingPercent,
                                hideEmails: hideAccountEmails,
                                activePinnedKey: activePinnedKey,
                                onSelectRing: { group in
                                    withAnimation(.snappy(duration: 0.2)) {
                                        pinnedRingID = AIUsageManager.pinnedRingKey(
                                            provider: provider,
                                            groupID: group.id
                                        )
                                    }
                                },
                                onRefresh: {
                                    Task {
                                        await usageManager.refresh(provider: provider, userInitiated: true)
                                    }
                                }
                            )
                        }
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if usageManager.lastGlobalRefresh == nil {
                Task {
                    await usageManager.refreshAllEnabled(userInitiated: false)
                }
            }
        }
    }

    private var emptyProvidersView: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 4)
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("No AI Providers Enabled")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
            Button {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            } label: {
                Text("Configure in Settings")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.effectiveAccent.opacity(0.85)))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func relativeTimeString(from date: Date) -> String {
        let sec = Int(Date().timeIntervalSince(date))
        if sec < 15 { return "just now" }
        if sec < 60 { return "\(sec)s ago" }
        let min = sec / 60
        if min < 60 { return "\(min)m ago" }
        return "\(min / 60)h ago"
    }
}

private struct NotchAIProviderCompactCard: View {
    let provider: AIProviderID
    let snapshot: AIProviderSnapshot?
    let isRefreshing: Bool
    let isLiquidGlass: Bool
    let showRemaining: Bool
    let hideEmails: Bool
    let activePinnedKey: String?
    let onSelectRing: (AIUsageRingGroup) -> Void
    let onRefresh: () -> Void

    @State private var isHovering: Bool = false

    /// Concentric outer card radius: R_outer - d = 28 - 14 = 14pt (24 - 10 = 14pt unscaled)
    private let cardCornerRadius: CGFloat = 14

    /// Concentric inner highlight tile radius: R_card - 5pt inset = 9pt
    private let nestedTileCornerRadius: CGFloat = 9

    private func isRingPinned(_ group: AIUsageRingGroup) -> Bool {
        activePinnedKey == AIUsageManager.pinnedRingKey(provider: provider, groupID: group.id)
    }

    private var ringGroups: [AIUsageRingGroup] {
        guard let windows = snapshot?.windows, !windows.isEmpty else { return [] }
        return AIUsageRingGroup.build(from: windows)
    }

    var body: some View {
        let groups = ringGroups
        VStack(alignment: .leading, spacing: 3) {
            // Compact Card Header
            HStack(spacing: 4) {
                Circle()
                    .fill(provider.accentColor.opacity(0.22))
                    .frame(width: 15, height: 15)
                    .overlay {
                        AIProviderIconView(provider: provider, size: 9.5)
                            .foregroundStyle(provider.accentColor)
                    }

                Text(provider.shortName)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                Spacer(minLength: 2)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.58)
                } else if isHovering {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                } else if let balance = snapshot?.balance, !groups.isEmpty {
                    Text(balance.compactFormattedRemaining)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(provider.accentColor.opacity(0.95))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(provider.accentColor.opacity(0.14)))
                        .lineLimit(1)
                } else if groups.count > 3 {
                    Text("+\(groups.count - 3)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                } else if let plan = snapshot?.planName, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(provider.accentColor.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // Card Content: Concentric Dual/Single Rings, Balance, or Error
            if let snapshot {
                if !groups.isEmpty {
                    let visibleGroups = Array(groups.prefix(3))
                    if visibleGroups.count == 1, let single = visibleGroups.first {
                        singleGroupRow(single)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(visibleGroups) { group in
                                multiGroupCell(group)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                } else if let balance = snapshot.balance {
                    balanceContent(balance)
                } else if let note = snapshot.statusNote {
                    Text(note)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                } else if let err = snapshot.errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange.opacity(0.85))
                        Text(err)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
            } else {
                Text("Waiting…")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color.white.opacity(isLiquidGlass ? (isHovering ? 0.14 : 0.10) : (isHovering ? 0.11 : 0.075)))
                .overlay {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isLiquidGlass ? 0.24 : 0.14),
                                    Color.white.opacity(isLiquidGlass ? 0.07 : 0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Single Group Layout (Ring + Side Legend)

    @ViewBuilder
    private func singleGroupRow(_ group: AIUsageRingGroup) -> some View {
        let outerPct = displayedPercent(for: group.outerWindow)
        let outerCol = provider.outerRingColor(for: group.outerWindow)
        let isPinned = isRingPinned(group)

        Button {
            onSelectRing(group)
        } label: {
            Group {
                if let inner = group.innerWindow {
                    let innerPct = displayedPercent(for: inner)
                    let innerCol = provider.innerRingColor(for: inner)

                    HStack(spacing: 8) {
                        AIUsageDualRingGauge(
                            outerProgress: outerPct / 100.0,
                            innerProgress: innerPct / 100.0,
                            outerColor: outerCol,
                            innerColor: innerCol,
                            size: 34,
                            outerLineWidth: 3.1,
                            innerLineWidth: 2.8,
                            ringGap: 2.0
                        )

                        VStack(alignment: .leading, spacing: 2.5) {
                            dualLegendLine(
                                dotColor: outerCol,
                                tag: "5h",
                                percent: outerPct,
                                reset: group.outerWindow.resetCountdownText
                            )
                            dualLegendLine(
                                dotColor: innerCol,
                                tag: "7d",
                                percent: innerPct,
                                reset: inner.resetCountdownText
                            )
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 8) {
                        AIUsageSingleRingGauge(
                            progress: outerPct / 100.0,
                            color: outerCol,
                            centerLabel: String(format: "%.0f%%", outerPct),
                            size: 33,
                            lineWidth: 3.0
                        )

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(group.label)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)

                            if let resetText = group.outerWindow.resetCountdownText {
                                Text("↻ \(resetText)")
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.50))
                                    .lineLimit(1)
                            } else if let detail = group.outerWindow.detailText {
                                Text(detail)
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous)
                    .fill(isPinned ? provider.accentColor.opacity(0.14) : Color.clear)
                    .overlay {
                        if isPinned {
                            RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous)
                                .strokeBorder(provider.accentColor.opacity(0.58), lineWidth: 0.9)
                        }
                    }
            }
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(provider.accentColor)
                        .padding(3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltipText(for: group, isPinned: isPinned))
    }

    @ViewBuilder
    private func dualLegendLine(dotColor: Color, tag: String, percent: Double, reset: String?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(tag)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 15, alignment: .leading)
            Text(String(format: "%.0f%%", percent))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
            if let reset {
                Text(reset)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Multi-Group Layout (2–3 Concentric/Single Rings Side by Side)

    @ViewBuilder
    private func multiGroupCell(_ group: AIUsageRingGroup) -> some View {
        let outerPct = displayedPercent(for: group.outerWindow)
        let outerCol = provider.outerRingColor(for: group.outerWindow)
        let isPinned = isRingPinned(group)
        let ringDiameter: CGFloat = 24

        Button {
            onSelectRing(group)
        } label: {
            VStack(spacing: 1.5) {
                if let inner = group.innerWindow {
                    let innerPct = displayedPercent(for: inner)
                    let innerCol = provider.innerRingColor(for: inner)

                    AIUsageDualRingGauge(
                        outerProgress: outerPct / 100.0,
                        innerProgress: innerPct / 100.0,
                        outerColor: outerCol,
                        innerColor: innerCol,
                        size: ringDiameter,
                        outerLineWidth: 2.5,
                        innerLineWidth: 2.3,
                        ringGap: 1.4
                    )

                    Text(group.label)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .truncationMode(.tail)

                    HStack(spacing: 1) {
                        Text(String(format: "%.0f%%", outerPct))
                            .foregroundStyle(outerCol)
                        Text("/")
                            .foregroundStyle(.white.opacity(0.32))
                        Text(String(format: "%.0f%%", innerPct))
                            .foregroundStyle(innerCol)
                    }
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                } else {
                    AIUsageSingleRingGauge(
                        progress: outerPct / 100.0,
                        color: outerCol,
                        centerLabel: nil,
                        size: ringDiameter,
                        lineWidth: 2.6
                    )

                    Text(group.label)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .truncationMode(.tail)

                    Text(String(format: "%.0f%%", outerPct))
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(outerCol)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous)
                    .fill(isPinned ? provider.accentColor.opacity(0.14) : Color.clear)
                    .overlay {
                        if isPinned {
                            RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous)
                                .strokeBorder(provider.accentColor.opacity(0.58), lineWidth: 0.9)
                        }
                    }
            }
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(provider.accentColor)
                        .padding(2.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltipText(for: group, isPinned: isPinned))
    }

    // MARK: - Balance Display (Single & Multi-Currency)

    @ViewBuilder
    private func balanceContent(_ balance: AIUsageBalance) -> some View {
        let allCurrencies = balance.allCurrencyBalances
        if allCurrencies.count > 1 {
            // Dual-currency display (e.g. DeepSeek USD + CNY)
            HStack(spacing: 6) {
                ForEach(allCurrencies.prefix(2)) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.currency)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                        Text(item.formattedRemaining)
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 34, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(balance.formattedRemaining)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let sub = balance.formattedBreakdown {
                    Text(sub)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let period = balance.periodLabel {
                    Text(period)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
    }

    // MARK: - Tooltip Helpers

    private func displayedPercent(for window: AIUsageRateWindow) -> Double {
        showRemaining ? window.remainingPercent : window.clampedUsedPercent
    }

    private func tooltipText(for group: AIUsageRingGroup, isPinned: Bool) -> String {
        var lines: [String] = []
        if let inner = group.innerWindow {
            lines.append(formatWindowTooltip(group.outerWindow, prefix: "Outer "))
            lines.append(formatWindowTooltip(inner, prefix: "Inner "))
        } else {
            lines.append(formatWindowTooltip(group.outerWindow, prefix: ""))
        }
        if let balance = snapshot?.balance {
            var balText = "Balance: \(balance.formattedRemaining)"
            if let breakdown = balance.formattedBreakdown {
                balText += " · \(breakdown)"
            }
            lines.append(balText)
        }
        lines.append(isPinned ? "Pinned to closed notch" : "Click to show in closed notch")
        return lines.joined(separator: "\n")
    }

    private func formatWindowTooltip(_ window: AIUsageRateWindow, prefix: String) -> String {
        var parts = [
            "\(prefix)\(window.label): \(Int(round(window.clampedUsedPercent)))% used (\(Int(round(window.remainingPercent)))% left)"
        ]
        if let detail = window.detailText {
            parts.append(detail)
        }
        if let reset = window.resetCountdownText {
            parts.append("resets in \(reset)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Compact AI Usage ring gauge displayed in the closed-notch right wing when the AI Usage tab is enabled.
struct ClosedNotchAIUsageRingView: View {
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    let containerSide: CGFloat

    private var ringSize: CGFloat {
        if containerSide <= 18 {
            return max(13, containerSide - 1)
        }
        return min(containerSide - 2, 22)
    }

    private var outerLineWidth: CGFloat {
        ringSize <= 16 ? 2.0 : 2.35
    }

    private var innerLineWidth: CGFloat {
        ringSize <= 16 ? 1.7 : 2.0
    }

    private var ringGap: CGFloat {
        ringSize <= 16 ? 1.15 : 1.45
    }

    var body: some View {
        let _ = enabledProvidersRaw
        Group {
            if let resolved = usageManager.resolvedPinnedRing(pinnedID: pinnedRingID) {
                let outerPct = showRemainingPercent
                    ? resolved.group.outerWindow.remainingPercent
                    : resolved.group.outerWindow.clampedUsedPercent
                let outerCol = resolved.provider.outerRingColor(for: resolved.group.outerWindow)

                if let inner = resolved.group.innerWindow {
                    let innerPct = showRemainingPercent
                        ? inner.remainingPercent
                        : inner.clampedUsedPercent
                    let innerCol = resolved.provider.innerRingColor(for: inner)

                    AIUsageDualRingGauge(
                        outerProgress: outerPct / 100.0,
                        innerProgress: innerPct / 100.0,
                        outerColor: outerCol,
                        innerColor: innerCol,
                        size: ringSize,
                        outerLineWidth: outerLineWidth,
                        innerLineWidth: innerLineWidth,
                        ringGap: ringGap,
                        outerTrackColor: Color.white.opacity(0.18),
                        innerTrackColor: Color.white.opacity(0.14)
                    )
                } else {
                    AIUsageSingleRingGauge(
                        progress: outerPct / 100.0,
                        color: outerCol,
                        centerLabel: nil,
                        size: ringSize,
                        lineWidth: outerLineWidth,
                        trackColor: Color.white.opacity(0.18)
                    )
                }
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: outerLineWidth)
                    .frame(width: ringSize, height: ringSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
/// Compact AI provider icon displayed in the closed-notch left wing when media is idle.
struct ClosedNotchAIUsageProviderIconView: View {
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    let containerSide: CGFloat

    private var badgeSize: CGFloat {
        // Match ClosedNotchAIUsageRingView.ringSize so left & right circular caps
        // have identical diameter and concentric clearance inside the closed ends.
        if containerSide <= 18 {
            return max(13, containerSide - 1)
        }
        return min(containerSide - 2, 22)
    }

    var body: some View {
        let _ = enabledProvidersRaw
        let resolved = usageManager.resolvedPinnedRing(pinnedID: pinnedRingID)
        let accent = resolved?.provider.accentColor ?? Color.effectiveAccent

        ZStack {
            Circle()
                .fill(accent.opacity(0.22))
                .overlay {
                    Circle()
                        .strokeBorder(accent.opacity(0.45), lineWidth: 0.7)
                }

            if let provider = resolved?.provider {
                AIProviderIconView(provider: provider, size: max(10, badgeSize * 0.56))
                    .foregroundStyle(accent)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: max(8.5, badgeSize * 0.48), weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Compact centered AI Usage percentage summary displayed inside the glass center on non-notched
/// screens when media is idle (replacing the inline closed lyrics area).
struct ClosedNotchAIUsageSummaryView: View {
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    var body: some View {
        let _ = enabledProvidersRaw
        Group {
            if let resolved = usageManager.resolvedPinnedRing(pinnedID: pinnedRingID) {
                let outerPct = showRemainingPercent
                    ? resolved.group.outerWindow.remainingPercent
                    : resolved.group.outerWindow.clampedUsedPercent
                let outerCol = resolved.provider.outerRingColor(for: resolved.group.outerWindow)
                let allGroups = usageManager.snapshots[resolved.provider].map {
                    AIUsageRingGroup.build(from: $0.windows)
                } ?? []
                let titleText = allGroups.count > 1 ? resolved.group.label : resolved.provider.shortName

                HStack(spacing: 4) {
                    Text(titleText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("·")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))

                    if let inner = resolved.group.innerWindow {
                        let innerPct = showRemainingPercent
                            ? inner.remainingPercent
                            : inner.clampedUsedPercent
                        let innerCol = resolved.provider.innerRingColor(for: inner)

                        HStack(spacing: 2) {
                            Text(String(format: "%.0f%%", outerPct))
                                .foregroundStyle(outerCol)
                            Text("/")
                                .foregroundStyle(.white.opacity(0.42))
                            Text(String(format: "%.0f%%", innerPct))
                                .foregroundStyle(innerCol)
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                    } else {
                        Text(String(format: "%.0f%%", outerPct))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(outerCol)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .shadow(color: .black.opacity(0.65), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(0.40), radius: 2.5, x: 0, y: 0)
            } else {
                Text("AI Usage")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .shadow(color: .black.opacity(0.55), radius: 1, x: 0, y: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

