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
    @Environment(\.notchGlassInk) private var ink
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageHideAccountEmails) private var hideAccountEmails
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw
    @Default(.aiUsagePinnedRingID) private var pinnedRingID

    private func gridColumns(for providerCount: Int) -> [GridItem] {
        let count = (providerCount == 2 || providerCount == 4) ? 2 : 3
        return Array(
            repeating: GridItem(.flexible(minimum: 110), spacing: 6),
            count: count
        )
    }

    var body: some View {
        let providers = usageManager.enabledProviders
        VStack(spacing: 5) {
            // Slim top toolbar
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.effectiveAccent)
                    Text("AI Usage")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.primary(0.92))
                    if let lastRefreshed = usageManager.lastGlobalRefresh {
                        Text("· \(Self.relativeTimeString(from: lastRefreshed))")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.tertiary(0.45))
                    }
                }

                Spacer()

                // Compact legend for concentric dual rings
                HStack(spacing: 3) {
                    Image(systemName: "circle.circle")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(ink.secondary(0.55))
                    Text("Outer 5h · Inner 7d")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.tertiary(0.45))
                }
                .padding(.trailing, 2)

                Button {
                    showRemainingPercent.toggle()
                } label: {
                    Text(showRemainingPercent ? "Left %" : "Used %")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.primary(0.78))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(ink.surface(liquidGlassNotch ? 0.12 : 0.09))
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
                    .foregroundStyle(ink.primary(0.84))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(ink.surface(liquidGlassNotch ? 0.14 : 0.10))
                    )
                }
                .buttonStyle(.plain)
                .disabled(usageManager.isRefreshing)
            }
            .frame(height: 18)

            if providers.isEmpty {
                emptyProvidersView
            } else {
                let resolvedPinned = usageManager.resolvedPinnedItem(pinnedID: pinnedRingID)
                let activePinnedKey = resolvedPinned?.pinnedKey

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: gridColumns(for: providers.count), spacing: 6) {
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
                                onSelectBalance: { currency in
                                    withAnimation(.snappy(duration: 0.2)) {
                                        pinnedRingID = AIUsageManager.pinnedBalanceKey(
                                            provider: provider,
                                            currency: currency
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
                .transformAnchorPreference(key: NotchAIUsageAnchorKey.self, value: .bounds) { value, anchor in
                    value.scrollViewport = anchor
                }
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
                .foregroundStyle(ink.secondary(0.5))
            Text("No AI Providers Enabled")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.primary(0.82))
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
    @Environment(\.notchGlassInk) private var ink
    @Environment(\.isAIUsageFlightActive) private var isAIUsageFlightActive
    let provider: AIProviderID
    let snapshot: AIProviderSnapshot?
    let isRefreshing: Bool
    let isLiquidGlass: Bool
    let showRemaining: Bool
    let hideEmails: Bool
    let activePinnedKey: String?
    let onSelectRing: (AIUsageRingGroup) -> Void
    let onSelectBalance: (String) -> Void
    let onRefresh: () -> Void

    @State private var isHovering: Bool = false

    /// Uniform card height so 2 full rows + 6pt grid gap (`64 * 2 + 6 = 134pt`) fit inside the
    /// open notch viewport without clipping bottom rounded corners.
    private let cardHeight: CGFloat = 64
    private let headerHeight: CGFloat = 15
    private let contentHeight: CGFloat = 36

    /// Concentric outer card radius: R_outer - d = 28 - 14 = 14pt (24 - 10 = 14pt unscaled)
    private let cardCornerRadius: CGFloat = 14

    /// Concentric inner highlight tile radius: R_card - 5pt inset = 9pt
    private let nestedTileCornerRadius: CGFloat = 9

    private func isRingPinned(_ group: AIUsageRingGroup) -> Bool {
        activePinnedKey == AIUsageManager.pinnedRingKey(provider: provider, groupID: group.id)
    }

    private func isBalancePinned(currency: String) -> Bool {
        activePinnedKey == AIUsageManager.pinnedBalanceKey(provider: provider, currency: currency)
    }

    private var ringGroups: [AIUsageRingGroup] {
        guard let windows = snapshot?.windows, !windows.isEmpty else { return [] }
        return AIUsageRingGroup.build(from: windows)
    }

    var body: some View {
        let groups = ringGroups
        VStack(alignment: .leading, spacing: 3) {
            // Compact Card Header (5pt card padding + 3pt header horizontal inset = 8pt optical margin)
            HStack(spacing: 4) {
                Circle()
                    .fill(provider.accentColor.opacity(0.22))
                    .frame(width: 15, height: 15)
                    .overlay {
                        AIProviderIconView(provider: provider, size: 9.5)
                            .foregroundStyle(ink.accent(provider.accentColor))
                    }

                Text(provider.shortName)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.primary(0.95))
                    .lineLimit(1)

                Spacer(minLength: 2)

                // A funded balance (top-up money or prepaid credits) sits beside the rings: it is
                // a wallet, not a quota, so it never becomes a ring of its own.
                if let balance = snapshot?.balance,
                   !groups.isEmpty,
                   let primary = balance.allCurrencyBalances.first
                {
                    let pinned = isBalancePinned(currency: primary.currency)
                    Button {
                        onSelectBalance(primary.currency)
                    } label: {
                        HStack(spacing: 2.5) {
                            if pinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 6, weight: .bold))
                            }
                            Text(balance.compactFormattedRemaining)
                        }
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink.accent(provider.accentColor).opacity(0.95))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 0.5)
                        .background(
                            Capsule()
                                .fill(provider.accentColor.opacity(pinned ? 0.22 : 0.14))
                                .overlay {
                                    if pinned {
                                        Capsule()
                                            .strokeBorder(provider.accentColor.opacity(0.65), lineWidth: 0.8)
                                    }
                                }
                        )
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(balanceTooltipText(for: balance, item: primary, isPinned: pinned))
                }

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.58)
                } else if isHovering {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ink.primary(0.78))
                    }
                    .buttonStyle(.plain)
                } else if groups.count > 3 {
                    Text("+\(groups.count - 3)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink.secondary(0.55))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(ink.surface(0.10)))
                } else if let plan = snapshot?.planName, !plan.isEmpty, snapshot?.balance == nil || groups.isEmpty {
                    Text(plan)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.accent(provider.accentColor).opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if groups.isEmpty, let balance = snapshot?.balance {
                    let currencies = balance.allCurrencyBalances
                    if !currencies.isEmpty {
                        Text(currencies.prefix(2).map(\.currency).joined(separator: "·"))
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ink.accent(provider.accentColor).opacity(0.82))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 3)
            .frame(height: headerHeight)

            // Card Content: Strictly fixed 36pt body height so all cards share identical geometry
            Group {
                if let snapshot {
                    if !groups.isEmpty {
                        let visibleGroups = Array(groups.prefix(3))
                        if visibleGroups.count == 1, let single = visibleGroups.first {
                            singleGroupRow(single)
                        } else if visibleGroups.count == 2 {
                            HStack(spacing: 4) {
                                ForEach(visibleGroups) { group in
                                    multiGroupHorizontalCell(group)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        } else {
                            HStack(spacing: 3) {
                                ForEach(visibleGroups) { group in
                                    multiGroupCompactCell(group)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    } else if let balance = snapshot.balance {
                        balanceContent(balance)
                    } else if let note = snapshot.statusNote {
                        Text(note)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.secondary(0.65))
                            .lineLimit(2)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else if let err = snapshot.errorMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.orange.opacity(0.85))
                            Text(err)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(ink.secondary(0.55))
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else {
                        Color.clear
                    }
                } else {
                    Text("Waiting…")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.tertiary(0.45))
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: .leading)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(ink.surface(isLiquidGlass ? (isHovering ? 0.14 : 0.10) : (isHovering ? 0.11 : 0.075)))
                .overlay {
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    ink.border(isLiquidGlass ? 0.24 : 0.14),
                                    ink.border(isLiquidGlass ? 0.07 : 0.05)
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

    // MARK: - Shared Concentric Pinnable Tile Shell

    @ViewBuilder
    private func pinnableTile<Content: View>(
        isPinned: Bool,
        pinSize: CGFloat = 6,
        pinPadding: CGFloat = 3,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: alignment)
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
                        .font(.system(size: pinSize, weight: .bold))
                        .foregroundStyle(provider.accentColor)
                        .padding(pinPadding)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: nestedTileCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func anchoredOpenRing<Content: View>(
        isPinned: Bool,
        metrics: AIUsageRingFlightMetrics,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .conditionalModifier(isPinned) { view in
                view
                    .anchorPreference(key: NotchAIUsageAnchorKey.self, value: .bounds) {
                        NotchAIUsageAnchorPayload(openRing: $0, openMetrics: metrics)
                    }
                    .opacity(isAIUsageFlightActive ? 0 : 1)
                    .animation(nil, value: isAIUsageFlightActive)
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
            pinnableTile(isPinned: isPinned, pinSize: 6.5, pinPadding: 3) {
                Group {
                    if let inner = group.innerWindow {
                        let innerPct = displayedPercent(for: inner)
                        let innerCol = provider.innerRingColor(for: inner)

                        HStack(spacing: 7.5) {
                            anchoredOpenRing(
                                isPinned: isPinned,
                                metrics: AIUsageRingFlightMetrics(
                                    ringSize: 30,
                                    outerLineWidth: 2.8,
                                    innerLineWidth: 2.5,
                                    ringGap: 1.7,
                                    iconSize: 9.5,
                                    showsCenterLabel: false
                                )
                            ) {
                                AIUsageDualRingGauge(
                                    outerProgress: outerPct / 100.0,
                                    innerProgress: innerPct / 100.0,
                                    outerColor: outerCol,
                                    innerColor: innerCol,
                                    size: 30,
                                    outerLineWidth: 2.8,
                                    innerLineWidth: 2.5,
                                    ringGap: 1.7
                                )
                            }
                            .frame(width: 33, height: 33)

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
                        HStack(spacing: 7.5) {
                            anchoredOpenRing(
                                isPinned: isPinned,
                                metrics: AIUsageRingFlightMetrics(
                                    ringSize: 30,
                                    outerLineWidth: 2.8,
                                    innerLineWidth: 2.8,
                                    ringGap: 0,
                                    iconSize: 9.5,
                                    showsCenterLabel: true
                                )
                            ) {
                                AIUsageSingleRingGauge(
                                    progress: outerPct / 100.0,
                                    color: outerCol,
                                    centerLabel: String(format: "%.0f%%", outerPct),
                                    size: 30,
                                    lineWidth: 2.8
                                )
                            }
                            .frame(width: 33, height: 33)

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(group.label)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(ink.primary(0.88))
                                    .lineLimit(1)

                                if let resetText = group.outerWindow.resetCountdownText {
                                    Text("↻ \(resetText)")
                                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(ink.secondary(0.50))
                                        .lineLimit(1)
                                } else if let detail = group.outerWindow.detailText {
                                    Text(detail)
                                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(ink.secondary(0.55))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 5)
            }
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
                .foregroundStyle(ink.secondary(0.62))
                .frame(width: 15, alignment: .leading)
            Text(String(format: "%.0f%%", percent))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(ink.primary(0.92))
            if let reset {
                Text(reset)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.tertiary(0.42))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func compactResetLine(
        for group: AIUsageRingGroup,
        fontSize: CGFloat,
        spacedPrefix: Bool
    ) -> some View {
        let outerReset = group.outerWindow.compactResetCountdownText
        let innerReset = group.innerWindow?.compactResetCountdownText

        if let outerReset, let innerReset, outerReset != innerReset {
            HStack(spacing: spacedPrefix ? 0.5 : 0) {
                Text(outerReset)
                Text("/")
                    .foregroundStyle(ink.tertiary(0.30))
                Text(innerReset)
            }
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(ink.tertiary(0.48))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        } else if let singleReset = outerReset ?? innerReset {
            Text(spacedPrefix ? "↻ \(singleReset)" : "↻\(singleReset)")
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(ink.tertiary(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Multi-Group Layout (2 Horizontal Cells or 3 Compact Vertical Cells)

    @ViewBuilder
    private func multiGroupHorizontalCell(_ group: AIUsageRingGroup) -> some View {
        let outerPct = displayedPercent(for: group.outerWindow)
        let outerCol = provider.outerRingColor(for: group.outerWindow)
        let isPinned = isRingPinned(group)

        Button {
            onSelectRing(group)
        } label: {
            pinnableTile(isPinned: isPinned, pinSize: 5.5, pinPadding: 2.5) {
                HStack(spacing: 4.5) {
                    if let inner = group.innerWindow {
                        let innerPct = displayedPercent(for: inner)
                        let innerCol = provider.innerRingColor(for: inner)

                        anchoredOpenRing(
                            isPinned: isPinned,
                            metrics: AIUsageRingFlightMetrics(
                                ringSize: 23,
                                outerLineWidth: 2.3,
                                innerLineWidth: 2.1,
                                ringGap: 1.2,
                                iconSize: 9.5,
                                showsCenterLabel: false
                            )
                        ) {
                            AIUsageDualRingGauge(
                                outerProgress: outerPct / 100.0,
                                innerProgress: innerPct / 100.0,
                                outerColor: outerCol,
                                innerColor: innerCol,
                                size: 23,
                                outerLineWidth: 2.3,
                                innerLineWidth: 2.1,
                                ringGap: 1.2
                            )
                        }
                        .frame(width: 26, height: 26)

                        VStack(alignment: .leading, spacing: 0.8) {
                            Text(group.label)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(ink.primary(0.84))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .truncationMode(.tail)
                                .padding(.trailing, isPinned ? 7 : 0)

                            HStack(spacing: 0.5) {
                                Text(String(format: "%.0f%%", outerPct))
                                    .foregroundStyle(ink.accent(outerCol))
                                Text("/")
                                    .foregroundStyle(ink.tertiary(0.32))
                                Text(String(format: "%.0f%%", innerPct))
                                    .foregroundStyle(ink.accent(innerCol))
                            }
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                            compactResetLine(for: group, fontSize: 6.8, spacedPrefix: true)
                        }
                    } else {
                        anchoredOpenRing(
                            isPinned: isPinned,
                            metrics: AIUsageRingFlightMetrics(
                                ringSize: 23,
                                outerLineWidth: 2.3,
                                innerLineWidth: 2.3,
                                ringGap: 0,
                                iconSize: 9.5,
                                showsCenterLabel: false
                            )
                        ) {
                            AIUsageSingleRingGauge(
                                progress: outerPct / 100.0,
                                color: outerCol,
                                centerLabel: nil,
                                size: 23,
                                lineWidth: 2.3
                            )
                        }
                        .frame(width: 26, height: 26)

                        VStack(alignment: .leading, spacing: 0.8) {
                            Text(group.label)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(ink.primary(0.84))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .truncationMode(.tail)
                                .padding(.trailing, isPinned ? 7 : 0)

                            Text(String(format: "%.0f%%", outerPct))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(ink.accent(outerCol))
                                .lineLimit(1)

                            compactResetLine(for: group, fontSize: 6.8, spacedPrefix: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .help(tooltipText(for: group, isPinned: isPinned))
    }

    @ViewBuilder
    private func multiGroupCompactCell(_ group: AIUsageRingGroup) -> some View {
        let outerPct = displayedPercent(for: group.outerWindow)
        let outerCol = provider.outerRingColor(for: group.outerWindow)
        let isPinned = isRingPinned(group)

        Button {
            onSelectRing(group)
        } label: {
            pinnableTile(isPinned: isPinned, pinSize: 5.5, pinPadding: 2, alignment: .leading) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(group.label)
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.primary(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .truncationMode(.tail)
                        .padding(.trailing, isPinned ? 7 : 0)

                    HStack(spacing: 2.5) {
                        if let inner = group.innerWindow {
                            let innerPct = displayedPercent(for: inner)
                            let innerCol = provider.innerRingColor(for: inner)

                            anchoredOpenRing(
                                isPinned: isPinned,
                                metrics: AIUsageRingFlightMetrics(
                                    ringSize: 15.5,
                                    outerLineWidth: 1.9,
                                    innerLineWidth: 1.7,
                                    ringGap: 1.0,
                                    iconSize: 9.5,
                                    showsCenterLabel: false
                                )
                            ) {
                                AIUsageDualRingGauge(
                                    outerProgress: outerPct / 100.0,
                                    innerProgress: innerPct / 100.0,
                                    outerColor: outerCol,
                                    innerColor: innerCol,
                                    size: 15.5,
                                    outerLineWidth: 1.9,
                                    innerLineWidth: 1.7,
                                    ringGap: 1.0
                                )
                            }
                            .frame(width: 17.5, height: 17.5)

                            VStack(alignment: .leading, spacing: 0.5) {
                                HStack(spacing: 0.5) {
                                    Text(String(format: "%.0f%%", outerPct))
                                        .foregroundStyle(ink.accent(outerCol))
                                    Text("/")
                                        .foregroundStyle(ink.tertiary(0.32))
                                    Text(String(format: "%.0f%%", innerPct))
                                        .foregroundStyle(ink.accent(innerCol))
                                }
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                                compactResetLine(for: group, fontSize: 6.5, spacedPrefix: false)
                            }
                        } else {
                            anchoredOpenRing(
                                isPinned: isPinned,
                                metrics: AIUsageRingFlightMetrics(
                                    ringSize: 15.5,
                                    outerLineWidth: 2.0,
                                    innerLineWidth: 2.0,
                                    ringGap: 0,
                                    iconSize: 9.5,
                                    showsCenterLabel: false
                                )
                            ) {
                                AIUsageSingleRingGauge(
                                    progress: outerPct / 100.0,
                                    color: outerCol,
                                    centerLabel: nil,
                                    size: 15.5,
                                    lineWidth: 2.0
                                )
                            }
                            .frame(width: 17.5, height: 17.5)

                            VStack(alignment: .leading, spacing: 0.5) {
                                Text(String(format: "%.0f%%", outerPct))
                                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ink.accent(outerCol))
                                    .lineLimit(1)

                                compactResetLine(for: group, fontSize: 6.5, spacedPrefix: false)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 3)
            }
        }
        .buttonStyle(.plain)
        .help(tooltipText(for: group, isPinned: isPinned))
    }

    // MARK: - Balance Display (Single & Multi-Currency)

    @ViewBuilder
    private func balanceContent(_ balance: AIUsageBalance) -> some View {
        let allCurrencies = balance.allCurrencyBalances
        if allCurrencies.count > 1 {
            // Dual-currency display (e.g. DeepSeek USD + CNY) — each currency independently pinnable
            HStack(spacing: 4) {
                ForEach(allCurrencies.prefix(2)) { item in
                    let isPinned = isBalancePinned(currency: item.currency)
                    Button {
                        onSelectBalance(item.currency)
                    } label: {
                        pinnableTile(isPinned: isPinned, pinSize: 5.5, pinPadding: 2.5) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.currency)
                                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(ink.secondary(0.48))
                                Text(item.formattedRemaining)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ink.primary(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                            }
                            .padding(.horizontal, 5)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(balanceTooltipText(for: balance, item: item, isPinned: isPinned))
                }
            }
        } else if let primary = allCurrencies.first {
            let isPinned = isBalancePinned(currency: primary.currency)
            Button {
                onSelectBalance(primary.currency)
            } label: {
                pinnableTile(isPinned: isPinned, pinSize: 6.5, pinPadding: 3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(balance.formattedRemaining)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(ink.primary(0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let sub = balance.formattedBreakdown(showRemaining: showRemaining) {
                            Text(sub)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(ink.secondary(0.52))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else if let period = balance.periodLabel {
                            Text(period)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(ink.secondary(0.52))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 5)
                }
            }
            .buttonStyle(.plain)
            .help(balanceTooltipText(for: balance, item: primary, isPinned: isPinned))
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(balance.formattedRemaining)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink.primary(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let sub = balance.formattedBreakdown(showRemaining: showRemaining) {
                    Text(sub)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.secondary(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let period = balance.periodLabel {
                    Text(period)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.secondary(0.52))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Tooltip Helpers

    private func balanceTooltipText(
        for balance: AIUsageBalance,
        item: AIUsageCurrencyBalance,
        isPinned: Bool
    ) -> String {
        var lines: [String] = ["\(provider.displayName) Balance (\(item.currency)): \(item.formattedRemaining)"]
        if let breakdown = balance.formattedBreakdown(showRemaining: showRemaining) {
            lines.append(breakdown)
        }
        lines.append(isPinned ? "Pinned to closed notch" : "Click to show in closed notch")
        return lines.joined(separator: "\n")
    }

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
            let balanceLabel = balance.allCurrencyBalances.contains { AIUsageCost.isCreditUnit($0.currency) }
                ? "Credits"
                : "Balance"
            var balText = "\(balanceLabel): \(balance.formattedRemaining)"
            if let breakdown = balance.formattedBreakdown(showRemaining: showRemaining) {
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
        if let reset = window.resetSummaryText {
            parts.append(reset)
        }
        return parts.joined(separator: " · ")
    }
}

/// Uses the same pinned item as the summary and right wing, without depending on media state.
struct ClosedNotchAIUsageProviderIconView: View {
    @Environment(\.notchGlassInk) private var ink
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    let containerSide: CGFloat

    var body: some View {
        let _ = enabledProvidersRaw
        Group {
            if let resolved = usageManager.resolvedPinnedItem(pinnedID: pinnedRingID) {
                switch resolved {
                case .ring(let provider, _), .balance(let provider, _, _):
                    AIProviderIconView(provider: provider, size: containerSide * 0.8)
                        .foregroundStyle(ink.accent(provider.accentColor))
                        .accessibilityLabel(Text(provider.shortName))
                }
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: containerSide * 0.65, weight: .semibold))
                    .foregroundStyle(Color.effectiveAccent)
            }
        }
        .frame(width: containerSide, height: containerSide)
    }
}

/// Compact AI Usage ring gauge with centered provider logo displayed in the closed-notch right wing
/// when the AI Usage tab is enabled.
struct ClosedNotchAIUsageRingView: View {
    @Environment(\.notchGlassInk) private var ink
    @Environment(\.isAIUsageFlightActive) private var isAIUsageFlightActive
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    let containerSide: CGFloat
    var showsProviderLogo: Bool = true

    private var outerLineWidth: CGFloat {
        if containerSide <= 18 {
            return max(1.15, min(1.55, containerSide * 0.095))
        }
        return min(2.6, max(1.75, containerSide * 0.082))
    }

    private var innerLineWidth: CGFloat {
        max(1.0, outerLineWidth * 0.85)
    }

    private var ringGap: CGFloat {
        min(1.4, max(0.55, containerSide * 0.04))
    }

    /// Ring stroke centerline diameter sized so the outer edge (`ringSize + outerLineWidth`)
    /// sits flush inside `containerSide`, matching the left album art thumbnail at any island
    /// height while leaving clean breathing room for the centered provider logo.
    private var ringSize: CGFloat {
        max(8, containerSide - outerLineWidth)
    }

    private var dualCenterIconSize: CGFloat {
        let innerSize = max(5, ringSize - (outerLineWidth + ringGap) * 2)
        let innerHoleDiameter = max(0, innerSize - innerLineWidth)
        return max(4.5, innerHoleDiameter * 0.62)
    }

    private var singleCenterIconSize: CGFloat {
        let innerHoleDiameter = max(0, ringSize - outerLineWidth)
        return max(5.5, innerHoleDiameter * 0.56)
    }

    private var balanceFontSize: CGFloat {
        min(13.5, max(9.0, containerSide * 0.62))
    }

    var body: some View {
        let _ = enabledProvidersRaw
        Group {
            if let resolved = usageManager.resolvedPinnedItem(pinnedID: pinnedRingID) {
                switch resolved {
                case .ring(let provider, let group):
                    let outerPct = showRemainingPercent
                        ? group.outerWindow.remainingPercent
                        : group.outerWindow.clampedUsedPercent
                    let outerCol = provider.outerRingColor(for: group.outerWindow)
                    let iconAccent = provider.accentColor

                    Group {
                        if let inner = group.innerWindow {
                            let innerPct = showRemainingPercent
                                ? inner.remainingPercent
                                : inner.clampedUsedPercent
                            let innerCol = provider.innerRingColor(for: inner)
                            let closedMetrics = AIUsageRingFlightMetrics(
                                ringSize: ringSize,
                                outerLineWidth: outerLineWidth,
                                innerLineWidth: innerLineWidth,
                                ringGap: ringGap,
                                iconSize: showsProviderLogo ? dualCenterIconSize : 0,
                                showsCenterLabel: false
                            )

                            ZStack {
                                AIUsageDualRingGauge(
                                    outerProgress: outerPct / 100.0,
                                    innerProgress: innerPct / 100.0,
                                    outerColor: outerCol,
                                    innerColor: innerCol,
                                    size: ringSize,
                                    outerLineWidth: outerLineWidth,
                                    innerLineWidth: innerLineWidth,
                                    ringGap: ringGap,
                                    outerTrackColor: ink.track(0.18),
                                    innerTrackColor: ink.track(0.14)
                                )
                                .anchorPreference(key: NotchAIUsageAnchorKey.self, value: .bounds) {
                                    NotchAIUsageAnchorPayload(closedRing: $0, closedMetrics: closedMetrics)
                                }
                                .opacity(isAIUsageFlightActive ? 0 : 1)
                                .animation(nil, value: isAIUsageFlightActive)

                                if showsProviderLogo {
                                    AIProviderIconView(provider: provider, size: dualCenterIconSize)
                                        .foregroundStyle(ink.accent(iconAccent))
                                        .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.45), radius: 1, x: 0, y: 0.5)
                                        .opacity(isAIUsageFlightActive ? 0 : 1)
                                        .animation(nil, value: isAIUsageFlightActive)
                                }
                            }
                        } else {
                            let closedMetrics = AIUsageRingFlightMetrics(
                                ringSize: ringSize,
                                outerLineWidth: outerLineWidth,
                                innerLineWidth: outerLineWidth,
                                ringGap: 0,
                                iconSize: showsProviderLogo ? singleCenterIconSize : 0,
                                showsCenterLabel: false
                            )

                            ZStack {
                                AIUsageSingleRingGauge(
                                    progress: outerPct / 100.0,
                                    color: outerCol,
                                    centerLabel: nil,
                                    size: ringSize,
                                    lineWidth: outerLineWidth,
                                    trackColor: ink.track(0.18)
                                )
                                .anchorPreference(key: NotchAIUsageAnchorKey.self, value: .bounds) {
                                    NotchAIUsageAnchorPayload(closedRing: $0, closedMetrics: closedMetrics)
                                }
                                .opacity(isAIUsageFlightActive ? 0 : 1)
                                .animation(nil, value: isAIUsageFlightActive)

                                if showsProviderLogo {
                                    AIProviderIconView(provider: provider, size: singleCenterIconSize)
                                        .foregroundStyle(ink.accent(iconAccent))
                                        .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.45), radius: 1, x: 0, y: 0.5)
                                        .opacity(isAIUsageFlightActive ? 0 : 1)
                                        .animation(nil, value: isAIUsageFlightActive)
                                }
                            }
                        }
                    }
                    .frame(width: containerSide, height: containerSide, alignment: .center)

                case .balance(let provider, _, let currencyBalance):
                    Text(currencyBalance.compactClosedNotchAmount)
                        .font(.system(size: balanceFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink.accent(provider.accentColor))
                        .lineLimit(1)
                        .padding(.leading, 2)
                        .padding(.trailing, 5)
                        .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.65), radius: 1, x: 0, y: 0.5)
                        .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.35), radius: 2, x: 0, y: 0)
                        .frame(minWidth: containerSide, minHeight: containerSide, maxHeight: containerSide, alignment: .center)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                ZStack {
                    Circle()
                        .stroke(ink.track(0.22), lineWidth: outerLineWidth)
                        .frame(width: ringSize, height: ringSize)

                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: max(6.5, singleCenterIconSize * 0.85), weight: .semibold))
                        .foregroundStyle(Color.effectiveAccent)
                }
                .frame(width: containerSide, height: containerSide, alignment: .center)
            }
        }
    }
}

/// Compact centered AI Usage percentage or balance summary displayed inside the glass center on
/// non-notched screens when media is idle (replacing the inline closed lyrics area).
struct ClosedNotchAIUsageSummaryView: View {
    @Environment(\.notchGlassInk) private var ink
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    var closedHeight: CGFloat? = nil

    private var fontSize: CGFloat {
        guard let closedHeight, closedHeight > 0 else { return 11 }
        return min(14, max(8.5, closedHeight * 0.46))
    }

    var body: some View {
        let _ = enabledProvidersRaw
        let textSize = fontSize
        Group {
            if let resolved = usageManager.resolvedPinnedItem(pinnedID: pinnedRingID) {
                switch resolved {
                case .ring(let provider, let group):
                    let outerPct = showRemainingPercent
                        ? group.outerWindow.remainingPercent
                        : group.outerWindow.clampedUsedPercent
                    let outerCol = provider.outerRingColor(for: group.outerWindow)
                    let allGroups = usageManager.snapshots[provider].map {
                        AIUsageRingGroup.build(from: $0.windows)
                    } ?? []
                    let titleText = allGroups.count > 1 ? group.label : provider.shortName

                    HStack(spacing: 4) {
                        Text(titleText)
                            .font(.system(size: textSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink.primary(0.86))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("·")
                            .font(.system(size: textSize, weight: .semibold))
                            .foregroundStyle(ink.tertiary(0.38))

                        if let inner = group.innerWindow {
                            let innerPct = showRemainingPercent
                                ? inner.remainingPercent
                                : inner.clampedUsedPercent
                            let innerCol = provider.innerRingColor(for: inner)

                            HStack(spacing: 2) {
                                Text(String(format: "%.0f%%", outerPct))
                                    .foregroundStyle(ink.accent(outerCol))
                                Text("/")
                                    .foregroundStyle(ink.tertiary(0.42))
                                Text(String(format: "%.0f%%", innerPct))
                                    .foregroundStyle(ink.accent(innerCol))
                            }
                            .font(.system(size: textSize, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                        } else {
                            Text(String(format: "%.0f%%", outerPct))
                                .font(.system(size: textSize, weight: .bold, design: .monospaced))
                                .foregroundStyle(ink.accent(outerCol))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                    .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.65), radius: 1, x: 0, y: 1)
                    .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.40), radius: 2.5, x: 0, y: 0)

                case .balance(let provider, _, _):
                    Text(provider.shortName)
                        .font(.system(size: textSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.primary(0.86))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.65), radius: 1, x: 0, y: 1)
                        .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.40), radius: 2.5, x: 0, y: 0)
                }
            } else {
                Text("AI Usage")
                    .font(.system(size: textSize, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.secondary(0.62))
                    .shadow(color: ink.isClearGlass ? .clear : .black.opacity(0.55), radius: 1, x: 0, y: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - AI Usage Ring & Inner Icon Flight Transition (Closed Wing <-> Open AI Tab)

private struct AIUsageFlightActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isAIUsageFlightActive: Bool {
        get { self[AIUsageFlightActiveKey.self] }
        set { self[AIUsageFlightActiveKey.self] = newValue }
    }
}

struct AIUsageRingFlightMetrics: Equatable {
    let ringSize: CGFloat
    let outerLineWidth: CGFloat
    let innerLineWidth: CGFloat
    let ringGap: CGFloat
    let iconSize: CGFloat
    let showsCenterLabel: Bool
}

struct NotchAIUsageAnchorPayload {
    var closedRing: Anchor<CGRect>?
    var closedMetrics: AIUsageRingFlightMetrics?
    var openRing: Anchor<CGRect>?
    var openMetrics: AIUsageRingFlightMetrics?
    var scrollViewport: Anchor<CGRect>?
}

struct NotchAIUsageAnchorKey: PreferenceKey {
    static var defaultValue = NotchAIUsageAnchorPayload()

    static func reduce(value: inout NotchAIUsageAnchorPayload, nextValue: () -> NotchAIUsageAnchorPayload) {
        let next = nextValue()
        value.closedRing = next.closedRing ?? value.closedRing
        value.closedMetrics = next.closedMetrics ?? value.closedMetrics
        value.openRing = next.openRing ?? value.openRing
        value.openMetrics = next.openMetrics ?? value.openMetrics
        value.scrollViewport = next.scrollViewport ?? value.scrollViewport
    }
}

/// Flies the closed-notch right-wing AI usage ring into (and back from) its matching ring slot
/// inside the expanded AI Usage card while fading the center provider icon out/in.
struct NotchAIUsageFlightOverlay: View {
    @Environment(\.notchGlassInk) private var ink
    @ObservedObject private var usageManager = AIUsageManager.shared
    @Default(.aiUsagePinnedRingID) private var pinnedRingID
    @Default(.aiUsageShowRemainingPercent) private var showRemainingPercent
    @Default(.aiUsageEnabledProviders) private var enabledProvidersRaw

    let anchors: NotchAIUsageAnchorPayload
    let proxy: GeometryProxy
    let isOpen: Bool
    let isAIUsageTab: Bool
    let isFlightActive: Bool
    let gestureProgress: CGFloat
    @Binding var hasClosedAnchor: Bool
    @Binding var hasOpenAnchor: Bool

    @State private var settledClosedRingRect: CGRect = .zero
    @State private var settledClosedMetrics: AIUsageRingFlightMetrics?
    @State private var settledOpenRingRect: CGRect = .zero
    @State private var settledOpenMetrics: AIUsageRingFlightMetrics?
    @State private var settledOpenCacheKey: String = ""

    private var currentClosedRingRect: CGRect? {
        guard let anchor = anchors.closedRing else { return nil }
        let rect = proxy[anchor]
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private var currentOpenRingRect: CGRect? {
        guard let anchor = anchors.openRing else { return nil }
        let rect = proxy[anchor]
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private var currentScrollViewport: CGRect? {
        guard let anchor = anchors.scrollViewport else { return nil }
        let rect = proxy[anchor]
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private var isOpenRingVisibleInViewport: Bool {
        guard let ringRect = currentOpenRingRect else { return false }
        guard let viewport = currentScrollViewport else { return true }
        return viewport.insetBy(dx: -4, dy: -4).contains(CGPoint(x: ringRect.midX, y: ringRect.midY))
    }

    var body: some View {
        let _ = enabledProvidersRaw
        let resolved = usageManager.resolvedPinnedItem(pinnedID: pinnedRingID)
        let pinnedRing: (provider: AIProviderID, group: AIUsageRingGroup)? = {
            if case .ring(let provider, let group) = resolved {
                return (provider, group)
            }
            return nil
        }()
        let openCacheKey = "\(resolved?.pinnedKey ?? "")|\(usageManager.enabledProviders.count)|\(Int(proxy.size.width.rounded()))x\(Int(proxy.size.height.rounded()))"
        let hasMatchingCachedOpen = settledOpenCacheKey == openCacheKey
            && settledOpenRingRect.width > 0
            && settledOpenMetrics != nil

        let closedRingRect: CGRect = (isFlightActive && settledClosedRingRect.width > 0)
            ? settledClosedRingRect
            : (currentClosedRingRect ?? settledClosedRingRect)
        let closedMetrics = (isFlightActive ? settledClosedMetrics : nil) ?? anchors.closedMetrics ?? settledClosedMetrics

        let openRingRect: CGRect = (isFlightActive && hasMatchingCachedOpen)
            ? settledOpenRingRect
            : (currentOpenRingRect ?? (hasMatchingCachedOpen ? settledOpenRingRect : .zero))
        let openMetrics = (isFlightActive && hasMatchingCachedOpen ? settledOpenMetrics : nil)
            ?? anchors.openMetrics
            ?? (hasMatchingCachedOpen ? settledOpenMetrics : nil)

        let targetIsOpen = isOpen && isAIUsageTab
        let resolvedOpenRingRect = openRingRect.width > 0 ? openRingRect : closedRingRect
        let targetRingRect = targetIsOpen ? resolvedOpenRingRect : closedRingRect
        let targetMetrics = targetIsOpen ? (openMetrics ?? closedMetrics) : (closedMetrics ?? openMetrics)
        let targetOpenProgress: CGFloat = (targetIsOpen && openRingRect.width > 0) ? 1.0 : 0.0
        let flightAnimation: Animation? = isFlightActive
            ? (isOpen ? NotchLyricMotion.openAnimation : NotchLyricMotion.closeAnimation)
            : nil
        let showFlight = isFlightActive
            && pinnedRing != nil
            && targetRingRect.width > 0
            && targetMetrics != nil
        let gestureOpacity: Double = (gestureProgress != 0 && isOpen)
            ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3)
            : 1.0

        ZStack(alignment: .topLeading) {
            if let pinnedRing, let metrics = targetMetrics, targetRingRect.width > 0 {
                let outerPct = showRemainingPercent
                    ? pinnedRing.group.outerWindow.remainingPercent
                    : pinnedRing.group.outerWindow.clampedUsedPercent
                let outerCol = pinnedRing.provider.outerRingColor(for: pinnedRing.group.outerWindow)
                let innerPct = pinnedRing.group.innerWindow.map {
                    showRemainingPercent ? $0.remainingPercent : $0.clampedUsedPercent
                }
                let innerCol = pinnedRing.group.innerWindow.map {
                    pinnedRing.provider.innerRingColor(for: $0)
                }

                NotchAIUsageRingFlightView(
                    provider: pinnedRing.provider,
                    midX: targetRingRect.midX,
                    midY: targetRingRect.midY,
                    ringSize: metrics.ringSize,
                    outerLineWidth: metrics.outerLineWidth,
                    innerLineWidth: metrics.innerLineWidth,
                    ringGap: metrics.ringGap,
                    openProgress: targetOpenProgress,
                    closedIconSize: closedMetrics?.iconSize ?? metrics.iconSize,
                    outerProgress: outerPct / 100.0,
                    innerProgress: innerPct.map { $0 / 100.0 },
                    outerColor: outerCol,
                    innerColor: innerCol,
                    centerLabel: (openMetrics?.showsCenterLabel == true && innerPct == nil)
                        ? String(format: "%.0f%%", outerPct)
                        : nil
                )
                .animation(flightAnimation, value: targetRingRect)
                .animation(flightAnimation, value: metrics)
                .animation(flightAnimation, value: targetOpenProgress)
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        .opacity(showFlight ? gestureOpacity : 0)
        .animation(nil, value: showFlight)
        .allowsHitTesting(false)
        .onAppear {
            syncSettledEndpoints(isPinnedRing: pinnedRing != nil, openCacheKey: openCacheKey)
        }
        .onChange(of: isFlightActive) { _, active in
            if !active {
                syncSettledEndpoints(isPinnedRing: pinnedRing != nil, openCacheKey: openCacheKey)
            }
        }
        .onChange(of: currentClosedRingRect) { _, _ in
            guard !isFlightActive, !isOpen else { return }
            syncClosedEndpoints(isPinnedRing: pinnedRing != nil)
        }
        .onChange(of: currentOpenRingRect) { _, _ in
            guard !isFlightActive, isOpen else { return }
            syncOpenEndpoints(isPinnedRing: pinnedRing != nil, openCacheKey: openCacheKey)
        }
        .onChange(of: isAIUsageTab) { _, _ in
            guard !isFlightActive else { return }
            syncOpenEndpoints(isPinnedRing: pinnedRing != nil, openCacheKey: openCacheKey)
        }
        .onChange(of: pinnedRingID) { _, _ in
            if !isOpen {
                settledOpenCacheKey = ""
                settledOpenRingRect = .zero
                settledOpenMetrics = nil
            }
            if !isFlightActive {
                syncSettledEndpoints(isPinnedRing: pinnedRing != nil, openCacheKey: openCacheKey)
            }
        }
    }

    private func syncSettledEndpoints(isPinnedRing: Bool, openCacheKey: String) {
        if !isOpen {
            syncClosedEndpoints(isPinnedRing: isPinnedRing)
        } else {
            syncOpenEndpoints(isPinnedRing: isPinnedRing, openCacheKey: openCacheKey)
        }
    }

    private func syncClosedEndpoints(isPinnedRing: Bool) {
        if isPinnedRing,
           let ringRect = currentClosedRingRect,
           let metrics = anchors.closedMetrics
        {
            settledClosedRingRect = ringRect
            settledClosedMetrics = metrics
            if !hasClosedAnchor { hasClosedAnchor = true }
        } else {
            if hasClosedAnchor { hasClosedAnchor = false }
        }
    }

    private func syncOpenEndpoints(isPinnedRing: Bool, openCacheKey: String) {
        if isAIUsageTab,
           isPinnedRing,
           isOpenRingVisibleInViewport,
           let ringRect = currentOpenRingRect,
           let metrics = anchors.openMetrics
        {
            settledOpenRingRect = ringRect
            settledOpenMetrics = metrics
            settledOpenCacheKey = openCacheKey
            if !hasOpenAnchor { hasOpenAnchor = true }
        } else {
            if hasOpenAnchor { hasOpenAnchor = false }
        }
    }
}

private struct NotchAIUsageRingFlightView: View, Animatable {
    @Environment(\.notchGlassInk) private var ink

    let provider: AIProviderID
    var midX: CGFloat
    var midY: CGFloat
    var ringSize: CGFloat
    var outerLineWidth: CGFloat
    var innerLineWidth: CGFloat
    var ringGap: CGFloat
    var openProgress: CGFloat

    let closedIconSize: CGFloat
    let outerProgress: Double
    let innerProgress: Double?
    let outerColor: Color
    let innerColor: Color?
    let centerLabel: String?

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<
            AnimatablePair<CGFloat, CGFloat>,
            AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>
        >
    > {
        get {
            AnimatablePair(
                AnimatablePair(midX, midY),
                AnimatablePair(
                    AnimatablePair(ringSize, outerLineWidth),
                    AnimatablePair(innerLineWidth, AnimatablePair(ringGap, openProgress))
                )
            )
        }
        set {
            midX = newValue.first.first
            midY = newValue.first.second
            ringSize = newValue.second.first.first
            outerLineWidth = newValue.second.first.second
            innerLineWidth = newValue.second.second.first
            ringGap = newValue.second.second.second.first
            openProgress = newValue.second.second.second.second
        }
    }

    var body: some View {
        let p = max(0, min(1, openProgress))
        let outerTrackOpacity = 0.18 + (0.13 - 0.18) * Double(p)
        let innerTrackOpacity = 0.14 + (0.11 - 0.14) * Double(p)
        let safeRingSize = max(6, ringSize)
        let safeOuterLW = max(0.8, outerLineWidth)
        let safeInnerLW = max(0.8, innerLineWidth)
        let safeGap = max(0, ringGap)
        let iconOpacity = max(0.0, min(1.0, 1.0 - Double(p) * 2.2))
        let iconScale = 0.82 + 0.18 * iconOpacity

        ZStack {
            if let innerProgress, let innerColor {
                AIUsageDualRingGauge(
                    outerProgress: outerProgress,
                    innerProgress: innerProgress,
                    outerColor: outerColor,
                    innerColor: innerColor,
                    size: safeRingSize,
                    outerLineWidth: safeOuterLW,
                    innerLineWidth: safeInnerLW,
                    ringGap: safeGap,
                    outerTrackColor: ink.track(outerTrackOpacity),
                    innerTrackColor: ink.track(innerTrackOpacity)
                )
            } else {
                let labelOpacity = max(0.0, min(1.0, (Double(p) - 0.35) / 0.65))
                AIUsageSingleRingGauge(
                    progress: outerProgress,
                    color: outerColor,
                    centerLabel: centerLabel,
                    size: safeRingSize,
                    lineWidth: safeOuterLW,
                    trackColor: ink.track(outerTrackOpacity),
                    labelColor: ink.primary(0.92 * labelOpacity)
                )
            }

            if closedIconSize > 0 && iconOpacity > 0.001 {
                AIProviderIconView(provider: provider, size: max(4, closedIconSize))
                    .foregroundStyle(ink.accent(provider.accentColor))
                    .shadow(
                        color: ink.isClearGlass ? .clear : .black.opacity(0.45 * iconOpacity),
                        radius: 1,
                        x: 0,
                        y: 0.5
                    )
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }
        }
        .position(x: midX, y: midY)
    }
}


