//
//  PowerNotchWidgets.swift
//  PowerNotchWidgets
//
//  Interactive Ring-Based Desktop Widgets for PowerNotch AI Usage.
//  Supports .systemSmall, .systemMedium, and .systemLarge with per-provider page flipping.
//

import AppIntents
import Charts
import SwiftUI
import WidgetKit

// MARK: - Timeline Entry & Provider

struct AIUsageWidgetEntry: TimelineEntry {
    let date: Date
    let payload: AIUsageWidgetPayload?
    let isPlaceholder: Bool
}

struct AIUsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> AIUsageWidgetEntry {
        AIUsageWidgetEntry(
            date: Date(),
            payload: AIUsageWidgetPayload.sample,
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (AIUsageWidgetEntry) -> Void) {
        let payload = AIUsageWidgetStore.loadPayload() ?? (context.isPreview ? AIUsageWidgetPayload.sample : nil)
        completion(
            AIUsageWidgetEntry(
                date: Date(),
                payload: payload,
                isPlaceholder: context.isPreview && AIUsageWidgetStore.loadPayload() == nil
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIUsageWidgetEntry>) -> Void) {
        let now = Date()
        let payload = AIUsageWidgetStore.loadPayload()
        let entry = AIUsageWidgetEntry(date: now, payload: payload, isPlaceholder: false)
        // Refresh periodically so relative reset countdowns ("2h 14m") stay accurate on the desktop.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget Definition

struct PowerNotchAIUsageWidget: Widget {
    let kind: String = AIUsageWidgetConstants.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIUsageTimelineProvider()) { entry in
            AIUsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("Monitor each configured AI provider with concentric usage rings and interactive page navigation.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Entry View

struct AIUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    let entry: AIUsageWidgetEntry

    private var familyKey: String {
        switch family {
        case .systemSmall: return "small"
        case .systemMedium: return "medium"
        case .systemLarge: return "large"
        default: return "other"
        }
    }

    var body: some View {
        let providers = entry.payload?.providers ?? []
        let resolved = AIUsageWidgetStore.resolvePage(in: providers, familyKey: familyKey)
        let showRemaining = entry.payload?.showRemainingPercent ?? true
        let updatedAt = resolved?.page.updatedAt ?? entry.payload?.updatedAt
        let selectedChartMetric = AIUsageWidgetStore.selectedChartMetric()
        let selectedChartRange = AIUsageWidgetStore.selectedChartRange()

        Group {
            if let resolved {
                switch family {
                case .systemSmall:
                    SmallProviderPageView(
                        page: resolved.page,
                        allProviders: providers,
                        pageIndex: resolved.index,
                        totalPages: resolved.total,
                        familyKey: familyKey,
                        showRemaining: showRemaining,
                        referenceDate: entry.date
                    )
                case .systemLarge:
                    LargeProviderPageView(
                        page: resolved.page,
                        allProviders: providers,
                        pageIndex: resolved.index,
                        totalPages: resolved.total,
                        familyKey: familyKey,
                        showRemaining: showRemaining,
                        selectedChartMetric: selectedChartMetric,
                        selectedChartRange: selectedChartRange,
                        updatedAt: updatedAt,
                        referenceDate: entry.date
                    )
                default:
                    MediumProviderPageView(
                        page: resolved.page,
                        allProviders: providers,
                        pageIndex: resolved.index,
                        totalPages: resolved.total,
                        familyKey: familyKey,
                        showRemaining: showRemaining,
                        updatedAt: updatedAt,
                        referenceDate: entry.date
                    )
                }
            } else {
                EmptyProvidersWidgetView(family: family)
            }
        }
        .containerBackground(for: .widget) {
            WidgetAmbientBackground(
                accentColor: resolved?.page.accentColor ?? .accentColor,
                renderingMode: renderingMode,
                colorScheme: colorScheme
            )
        }
    }
}

// MARK: - Ambient Background

private struct WidgetAmbientBackground: View {
    let accentColor: Color
    let renderingMode: WidgetRenderingMode
    let colorScheme: ColorScheme

    var body: some View {
        if renderingMode == .fullColor {
            ZStack {
                (colorScheme == .dark
                    ? Color(red: 0.08, green: 0.09, blue: 0.11)
                    : Color(red: 0.96, green: 0.97, blue: 0.99))

                RadialGradient(
                    colors: [
                        accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        accentColor.opacity(colorScheme == .dark ? 0.05 : 0.02),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 12,
                    endRadius: 230
                )
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Small Widget (Single Provider Page)

private struct SmallProviderPageView: View {
    let page: AIUsageWidgetProviderPage
    let allProviders: [AIUsageWidgetProviderPage]
    let pageIndex: Int
    let totalPages: Int
    let familyKey: String
    let showRemaining: Bool
    let referenceDate: Date

    var body: some View {
        VStack(spacing: 6) {
            // Top bar: Provider badge + shortName + compact page arrows
            HStack(spacing: 5) {
                ProviderHeaderBadge(page: page, iconSize: 10.5, boxSize: 18)

                Text(page.shortName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 2)

                if totalPages > 1 {
                    HStack(spacing: 3) {
                        Button(intent: AIUsageWidgetTurnPageIntent(step: -1, familyKey: familyKey)) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)

                        Button(intent: AIUsageWidgetTurnPageIntent(step: 1, familyKey: familyKey)) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)

            // Main ring showcase
            if page.ringGroups.count == 1, let group = page.ringGroups.first {
                VStack(spacing: 5) {
                    WidgetRingGroupGauge(
                        page: page,
                        group: group,
                        size: 76,
                        outerLineWidth: 7,
                        innerLineWidth: 5.5,
                        ringGap: 3.5,
                        showRemaining: showRemaining,
                        showCenterSubtitle: true
                    )

                    smallSingleGroupFooter(group: group)
                }
            } else if page.ringGroups.count > 1 {
                let visibleGroups = Array(page.ringGroups.prefix(3))
                let ringDiameter: CGFloat = visibleGroups.count == 2 ? 54 : 42
                HStack(spacing: visibleGroups.count == 2 ? 12 : 6) {
                    ForEach(visibleGroups) { group in
                        VStack(spacing: 3) {
                            WidgetRingGroupGauge(
                                page: page,
                                group: group,
                                size: ringDiameter,
                                outerLineWidth: visibleGroups.count == 2 ? 5.2 : 4.2,
                                innerLineWidth: visibleGroups.count == 2 ? 4.0 : 3.2,
                                ringGap: visibleGroups.count == 2 ? 2.6 : 2.0,
                                showRemaining: showRemaining,
                                showCenterSubtitle: false
                            )
                            Text(group.label)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)

                if let reset = page.ringGroups.first?.outerWindow.resetCountdownText(referenceDate: referenceDate) {
                    Text("Resets in \(reset)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let balance = page.balance {
                    Text(balance.compactFormattedRemaining)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(page.accentColor)
                        .lineLimit(1)
                }
            } else if let balance = page.balance {
                VStack(spacing: 4) {
                    Text(balance.periodLabel ?? "Balance")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(balance.formattedRemaining)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)

                    if let breakdown = balance.formattedBreakdown {
                        Text(breakdown)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    } else if let note = page.statusNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 4)
            } else {
                ProviderEmptyDataView(page: page, compact: true)
            }

            Spacer(minLength: 0)

            // Bottom page indicator dots
            if totalPages > 1 {
                PageDotsBar(
                    providers: allProviders,
                    activeIndex: pageIndex,
                    activeColor: page.accentColor,
                    familyKey: familyKey,
                    interactive: false
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func smallSingleGroupFooter(group: AIUsageWidgetRingGroup) -> some View {
        if let inner = group.innerWindow {
            let outerPct = Int(group.outerWindow.displayPercent(showRemaining: showRemaining).rounded())
            let innerPct = Int(inner.displayPercent(showRemaining: showRemaining).rounded())
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(page.outerRingColor(for: group.outerWindow))
                        .frame(width: 5, height: 5)
                    Text("5h \(outerPct)%")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.86))
                }
                HStack(spacing: 3) {
                    Circle()
                        .fill(page.innerRingColor(for: inner))
                        .frame(width: 5, height: 5)
                    Text("7d \(innerPct)%")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        } else if let reset = group.outerWindow.resetCountdownText(referenceDate: referenceDate) {
            Text("\(group.label) · \(reset)")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let balance = page.balance {
            Text(balance.compactFormattedRemaining)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(page.accentColor)
                .lineLimit(1)
        }
    }
}

// MARK: - Medium Widget (Single Provider Page — Ring Hero + Breakdown)

private struct MediumProviderPageView: View {
    let page: AIUsageWidgetProviderPage
    let allProviders: [AIUsageWidgetProviderPage]
    let pageIndex: Int
    let totalPages: Int
    let familyKey: String
    let showRemaining: Bool
    let updatedAt: Date?
    let referenceDate: Date

    var body: some View {
        VStack(spacing: 8) {
            // Top bar
            HStack(spacing: 6) {
                ProviderHeaderBadge(page: page, iconSize: 12, boxSize: 22)

                Text(page.displayName)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let plan = page.planName, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(page.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(page.accentColor.opacity(0.16)))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Refresh trigger
                Button(intent: AIUsageWidgetRefreshIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                if totalPages > 1 {
                    PaginationControlPill(
                        pageIndex: pageIndex,
                        totalPages: totalPages,
                        familyKey: familyKey
                    )
                }
            }

            // Center content
            if page.ringGroups.count == 1, let group = page.ringGroups.first {
                HStack(spacing: 14) {
                    WidgetRingGroupGauge(
                        page: page,
                        group: group,
                        size: 86,
                        outerLineWidth: 8,
                        innerLineWidth: 6.2,
                        ringGap: 4,
                        showRemaining: showRemaining,
                        showCenterSubtitle: true
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        WindowMetricRow(
                            window: group.outerWindow,
                            dotColor: page.outerRingColor(for: group.outerWindow),
                            showRemaining: showRemaining,
                            referenceDate: referenceDate
                        )

                        if let inner = group.innerWindow {
                            WindowMetricRow(
                                window: inner,
                                dotColor: page.innerRingColor(for: inner),
                                showRemaining: showRemaining,
                                referenceDate: referenceDate
                            )
                        }

                        if let balance = page.balance {
                            HStack(spacing: 5) {
                                Image(systemName: "creditcard.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(page.accentColor)
                                Text(balance.formattedRemaining)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(page.accentColor.opacity(0.14)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else if page.ringGroups.count > 1 {
                let visibleGroups = Array(page.ringGroups.prefix(4))
                let ringSize: CGFloat = visibleGroups.count <= 3 ? 64 : 54
                HStack(spacing: visibleGroups.count <= 3 ? 12 : 8) {
                    ForEach(visibleGroups) { group in
                        VStack(spacing: 4) {
                            WidgetRingGroupGauge(
                                page: page,
                                group: group,
                                size: ringSize,
                                outerLineWidth: visibleGroups.count <= 3 ? 6.0 : 5.0,
                                innerLineWidth: visibleGroups.count <= 3 ? 4.6 : 3.8,
                                ringGap: visibleGroups.count <= 3 ? 3.0 : 2.5,
                                showRemaining: showRemaining,
                                showCenterSubtitle: false
                            )

                            Text(group.label)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)

                            if let inner = group.innerWindow {
                                let oPct = Int(group.outerWindow.displayPercent(showRemaining: showRemaining).rounded())
                                let iPct = Int(inner.displayPercent(showRemaining: showRemaining).rounded())
                                Text("5h \(oPct)% · 7d \(iPct)%")
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            } else if let reset = group.outerWindow.resetCountdownText(referenceDate: referenceDate) {
                                Text(reset)
                                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            } else if let balance = page.balance {
                VStack(alignment: .leading, spacing: 5) {
                    Text(balance.periodLabel ?? "Available Balance")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(balance.formattedRemaining)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)

                    if let breakdown = balance.formattedBreakdown {
                        Text(breakdown)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let note = page.statusNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            } else {
                ProviderEmptyDataView(page: page, compact: false)
                    .frame(maxHeight: .infinity)
            }

            // Bottom strip: interactive page dots + legend / updated timestamp
            HStack(spacing: 6) {
                if totalPages > 1 {
                    PageDotsBar(
                        providers: allProviders,
                        activeIndex: pageIndex,
                        activeColor: page.accentColor,
                        familyKey: familyKey,
                        interactive: true
                    )
                } else if let acct = page.accountLabel, !acct.isEmpty {
                    Text(acct)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if page.ringGroups.contains(where: { $0.isDual }) {
                    Text("Outer 5h · Inner 7d")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.85))
                }

                if let updatedAt {
                    Text("· \(RelativeTimeFormatter.short(from: updatedAt, now: referenceDate))")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Large Widget (Upper Rings + Lower 30-Day Trend Chart + Provider Switcher)

private struct LargeProviderPageView: View {
    let page: AIUsageWidgetProviderPage
    let allProviders: [AIUsageWidgetProviderPage]
    let pageIndex: Int
    let totalPages: Int
    let familyKey: String
    let showRemaining: Bool
    let selectedChartMetric: AIUsageChartMetric
    let selectedChartRange: AIUsageChartRange
    let updatedAt: Date?
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Top bar
            HStack(alignment: .center, spacing: 8) {
                ProviderHeaderBadge(page: page, iconSize: 13.5, boxSize: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(page.displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    HStack(spacing: 5) {
                        if let plan = page.planName, !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(page.accentColor)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(page.accentColor.opacity(0.16)))
                                .lineLimit(1)
                        } else if let src = page.sourceLabel, !src.isEmpty {
                            Text(src)
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let updatedAt {
                            Text("Updated \(RelativeTimeFormatter.short(from: updatedAt, now: referenceDate))")
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button(intent: AIUsageWidgetRefreshIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                if totalPages > 1 {
                    PaginationControlPill(
                        pageIndex: pageIndex,
                        totalPages: totalPages,
                        familyKey: familyKey
                    )
                }
            }

            // Upper Section: Compact Rings (or Direct Numeric Balance — Zero Duplication)
            largeUpperQuotaSection

            // Lower Section: Tokens / Spend / Requests Line Chart
            LargeTrendCard(
                page: page,
                selectedMetric: selectedChartMetric,
                selectedRange: selectedChartRange,
                referenceDate: referenceDate
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            // Bottom Interactive Provider Selector Dock
            if totalPages > 1 {
                LargeProviderSwitcherBar(
                    providers: allProviders,
                    activeID: page.id,
                    familyKey: familyKey
                )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var largeUpperQuotaSection: some View {
        if page.ringGroups.count == 1, let group = page.ringGroups.first {
            HStack(spacing: 12) {
                WidgetRingGroupGauge(
                    page: page,
                    group: group,
                    size: 64,
                    outerLineWidth: 6.2,
                    innerLineWidth: 4.8,
                    ringGap: 3.0,
                    showRemaining: showRemaining,
                    showCenterSubtitle: true
                )

                VStack(alignment: .leading, spacing: 4.5) {
                    // Outer ring metadata (percentage already centered in ring -> show label + reset)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(page.outerRingColor(for: group.outerWindow))
                            .frame(width: 6, height: 6)
                            .widgetAccentable()
                        Text(group.outerWindow.label)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let reset = group.outerWindow.resetCountdownText(referenceDate: referenceDate) {
                            Text(reset)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Outer")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Inner ring metadata (only shown when dual ring exists -> unique inner % + reset)
                    if let inner = group.innerWindow {
                        let innerPct = Int(inner.displayPercent(showRemaining: showRemaining).rounded())
                        HStack(spacing: 5) {
                            Circle()
                                .fill(page.innerRingColor(for: inner))
                                .frame(width: 6, height: 6)
                                .widgetAccentable()
                            Text(inner.label)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let reset = inner.resetCountdownText(referenceDate: referenceDate) {
                                Text(reset)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text("\(innerPct)%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                                .contentTransition(.numericText())
                                .lineLimit(1)
                        }
                    } else if let detail = group.outerWindow.detailText, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let balance = page.balance {
                        HStack(spacing: 4) {
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(page.accentColor)
                            Text(balance.formattedRemaining)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                            if let breakdown = balance.formattedBreakdown {
                                Text("· \(breakdown)")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(page.accentColor.opacity(0.14)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else if page.ringGroups.count == 2 {
            HStack(spacing: 8) {
                ForEach(Array(page.ringGroups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 0.5, height: 34)
                    }
                    HStack(spacing: 8) {
                        WidgetRingGroupGauge(
                            page: page,
                            group: group,
                            size: 56,
                            outerLineWidth: 5.4,
                            innerLineWidth: 4.2,
                            ringGap: 2.6,
                            showRemaining: showRemaining,
                            showCenterSubtitle: false
                        )

                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(group.label)
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            if let inner = group.innerWindow {
                                let iPct = Int(inner.displayPercent(showRemaining: showRemaining).rounded())
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(page.innerRingColor(for: inner))
                                        .frame(width: 4.5, height: 4.5)
                                        .widgetAccentable()
                                    Text("7d \(iPct)%")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } else if let reset = group.outerWindow.resetCountdownText(referenceDate: referenceDate) {
                                Text(reset)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else if page.ringGroups.count > 2 {
            let visibleGroups = Array(page.ringGroups.prefix(4))
            let ringSize: CGFloat = visibleGroups.count == 3 ? 48 : 44
            HStack(spacing: visibleGroups.count == 3 ? 10 : 6) {
                ForEach(visibleGroups) { group in
                    VStack(spacing: 2) {
                        WidgetRingGroupGauge(
                            page: page,
                            group: group,
                            size: ringSize,
                            outerLineWidth: visibleGroups.count == 3 ? 4.6 : 4.2,
                            innerLineWidth: visibleGroups.count == 3 ? 3.6 : 3.2,
                            ringGap: visibleGroups.count == 3 ? 2.2 : 2.0,
                            showRemaining: showRemaining,
                            showCenterSubtitle: false
                        )

                        Text(group.label)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)

                        // Zero duplication: outer % is inside the ring; show only inner 7d % or reset countdown
                        if let inner = group.innerWindow {
                            let iPct = Int(inner.displayPercent(showRemaining: showRemaining).rounded())
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(page.innerRingColor(for: inner))
                                    .frame(width: 4.5, height: 4.5)
                                    .widgetAccentable()
                                Text("7d \(iPct)%")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else if let reset = group.outerWindow.resetCountdownText(referenceDate: referenceDate) {
                            Text(reset)
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else if let balance = page.balance {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(balance.periodLabel ?? "Available Balance")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(balance.formattedRemaining)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if let breakdown = balance.formattedBreakdown {
                        Text(breakdown)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let note = page.statusNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(page.accentColor.opacity(0.28), style: StrokeStyle(lineWidth: 3, dash: [3.5, 3.5]))
                        .frame(width: 36, height: 36)
                    WidgetProviderBrandIcon(
                        iconAssetName: page.iconAssetName,
                        symbolName: page.symbolName,
                        size: 15
                    )
                    .foregroundStyle(page.accentColor.opacity(0.85))
                    .widgetAccentable()
                }

                Text(page.errorMessage ?? page.statusNote ?? "Waiting for data…")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }
}

// MARK: - Large Widget 30-Day Trend Line Chart Card

private struct LargeTrendCard: View {
    let page: AIUsageWidgetProviderPage
    let selectedMetric: AIUsageChartMetric
    let selectedRange: AIUsageChartRange
    let referenceDate: Date

    private struct IndexedPoint: Identifiable {
        let index: Int
        let dayKey: String
        let shortDateLabel: String
        let value: Double

        var id: Int { index }
    }

    private var resolvedHistory: [AIUsageWidgetDailyPoint] {
        let window = selectedRange.points(for: page)
        if !window.isEmpty {
            return window
        }
        if selectedRange == .day {
            // Hour buckets only come from usage logs; an empty list is a real "no usage" answer.
            return []
        }
        // Build empty 30-day scaffold so axis labels remain clean
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return (0..<30).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return AIUsageWidgetDailyPoint(dayKey: df.string(from: date), tokens: 0, cost: 0, requests: 0)
        }
    }

    private var chartPoints: [IndexedPoint] {
        resolvedHistory.enumerated().map { idx, pt in
            IndexedPoint(
                index: idx,
                dayKey: pt.dayKey,
                shortDateLabel: pt.shortDateLabel,
                value: selectedMetric.value(for: pt)
            )
        }
    }

    private var activeSeriesColor: Color {
        metricColor(for: selectedMetric)
    }

    private func metricColor(for metric: AIUsageChartMetric) -> Color {
        switch metric {
        case .tokens: return page.accentColor
        case .cost: return Color(red: 0.96, green: 0.64, blue: 0.22)
        case .requests: return page.baseInnerColor
        }
    }

    var body: some View {
        let points = chartPoints
        let maxValue = points.map(\.value).max() ?? 0
        let hasData = maxValue > 0

        VStack(alignment: .leading, spacing: 6) {
            // Card Header: "Trend" + compact segmented range pill + latest/peak callout
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("Trend")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // Range pills: 1D needs hour buckets, 7D/30D slice the daily series.
                    HStack(spacing: 1.5) {
                        ForEach(AIUsageChartRange.allCases) { range in
                            rangePill(range)
                        }
                    }
                    .padding(1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .fixedSize()
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                if hasData {
                    let todayVal = points.last?.value ?? 0
                    let latestLabel = selectedRange == .day ? "Last" : "Today"
                    Text("\(latestLabel) \(formatMetricValue(todayVal, for: selectedMetric)) · Peak \(formatMetricValue(maxValue, for: selectedMetric))")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text(selectedRange == .day ? "Last 24h" : "Last \(selectedRange.totalLabel)")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }

            // 3 Interactive Metric Switcher Pills (Single-row compact chips)
            HStack(spacing: 4) {
                ForEach(AIUsageChartMetric.allCases) { metric in
                    metricPill(for: metric)
                }
            }

            // Smooth Line Chart
            if hasData {
                trendChartView(points: points, maxValue: maxValue)
            } else {
                ZStack {
                    // Subtle flat baseline
                    VStack(spacing: 0) {
                        Spacer()
                        Rectangle()
                            .fill(activeSeriesColor.opacity(0.22))
                            .frame(height: 1)
                            .padding(.bottom, 16)
                    }

                    VStack(spacing: 3) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.7))
                        Text("No \(selectedRange.totalLabel) \(selectedMetric.shortLabel.lowercased()) yet")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    @ViewBuilder
    private func trendChartView(points: [IndexedPoint], maxValue: Double) -> some View {
        let yUpper = niceUpperBound(maxValue)
        let midIndex = points.count / 2
        let lastIndex = max(0, points.count - 1)
        let xTickIndices: [Int] = {
            if points.count <= 1 { return [0] }
            if points.count == 2 { return [0, 1] }
            return [0, midIndex, lastIndex]
        }()
        let seriesLabel = selectedMetric.shortLabel
        let seriesColor = activeSeriesColor
        let areaGradient = LinearGradient(
            colors: [
                seriesColor.opacity(0.28),
                seriesColor.opacity(0.02)
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        GeometryReader { proxy in
            let yTickValues: [Double] = proxy.size.height >= 64 ? [0, yUpper * 0.5, yUpper] : [0, yUpper]

            Chart {
                ForEach(points) { pt in
                    AreaMark(
                        x: .value("Day", pt.index),
                        yStart: .value("Base", 0.0),
                        yEnd: .value(seriesLabel, pt.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(areaGradient)

                    LineMark(
                        x: .value("Day", pt.index),
                        y: .value(seriesLabel, pt.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(seriesColor)
                }

                if let last = points.last, last.value > 0 {
                    PointMark(
                        x: .value("Day", last.index),
                        y: .value(seriesLabel, last.value)
                    )
                    .symbolSize(20)
                    .foregroundStyle(seriesColor)
                } else if let peak = points.max(by: { $0.value < $1.value }), peak.value > 0 {
                    PointMark(
                        x: .value("Day", peak.index),
                        y: .value(seriesLabel, peak.value)
                    )
                    .symbolSize(20)
                    .foregroundStyle(seriesColor)
                }
            }
            .chartXScale(domain: 0...max(1, lastIndex))
            .chartYScale(domain: 0...yUpper)
            .chartXAxis {
                AxisMarks(values: xTickIndices) { value in
                    if let idx = value.as(Int.self), idx >= 0, idx < points.count {
                        let anchor: UnitPoint = {
                            if idx == 0 && points.count > 1 { return .topLeading }
                            if idx == lastIndex && points.count > 1 { return .topTrailing }
                            return .top
                        }()
                        AxisValueLabel(anchor: anchor) {
                            Text(idx == lastIndex ? (selectedRange == .day ? "Now" : "Today") : points[idx].shortDateLabel)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.85))
                                .fixedSize()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: yTickValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.primary.opacity(0.10))
                    if let num = value.as(Double.self) {
                        AxisValueLabel {
                            Text(formatAxisValue(num, for: selectedMetric))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.85))
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .padding(.top, 2)
            .widgetAccentable()
        }
        .frame(minHeight: 56, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rangePill(_ range: AIUsageChartRange) -> some View {
        let isActive = range == selectedRange
        Button(intent: AIUsageWidgetSelectChartRangeIntent(range: range)) {
            Text(range.shortLabel)
                .font(.system(size: 8.5, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isActive ? page.accentColor.opacity(0.24) : Color.clear)
                        .overlay {
                            if isActive {
                                Capsule().strokeBorder(page.accentColor.opacity(0.5), lineWidth: 0.6)
                            }
                        }
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func metricPill(for metric: AIUsageChartMetric) -> some View {
        let isActive = metric == selectedMetric
        let tint = metricColor(for: metric)
        let totalText = formattedRangeTotal(for: metric)

        Button(intent: AIUsageWidgetSelectChartMetricIntent(metric: metric)) {
            HStack(spacing: 3) {
                Circle()
                    .fill(isActive ? tint : tint.opacity(0.55))
                    .frame(width: 4.5, height: 4.5)
                    .widgetAccentable()
                Text(metric.shortLabel)
                    .font(.system(size: 8.5, weight: isActive ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(totalText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 6.5)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? tint.opacity(0.16) : Color.primary.opacity(0.05))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tint.opacity(0.50), lineWidth: 0.85)
                        }
                    }
            )
        }
        .buttonStyle(.plain)
    }

    /// Totals follow the selected range, so a 1D pill never advertises a 30-day number.
    private func formattedRangeTotal(for metric: AIUsageChartMetric) -> String {
        let window = resolvedHistory
        switch metric {
        case .tokens:
            let t = window.reduce(Int64(0)) { $0 + max(0, $1.tokens) }
            return t > 0 ? formatCompactCount(Double(t)) : "—"
        case .cost:
            let c = window.reduce(0) { $0 + max(0, $1.cost) }
            return c > 0.0001 ? formatCompactCurrency(c, symbol: page.costCurrencySymbol) : "—"
        case .requests:
            let r = window.reduce(0) { $0 + max(0, $1.requests) }
            return r > 0 ? formatCompactCount(Double(r)) : "—"
        }
    }

    private func formatMetricValue(_ value: Double, for metric: AIUsageChartMetric) -> String {
        switch metric {
        case .tokens, .requests:
            return formatCompactCount(value)
        case .cost:
            return formatCompactCurrency(value, symbol: page.costCurrencySymbol)
        }
    }

    private func formatAxisValue(_ value: Double, for metric: AIUsageChartMetric) -> String {
        if value <= 0 { return "0" }
        switch metric {
        case .tokens, .requests:
            return formatCompactCount(value)
        case .cost:
            return formatAxisCurrency(value, symbol: page.costCurrencySymbol)
        }
    }

    private func formatAxisCurrency(_ value: Double, symbol: String) -> String {
        if value >= 1000 {
            let k = value / 1000
            let formatted = abs(k - k.rounded()) < 0.05 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
            return "\(symbol)\(formatted)"
        } else if value >= 10 {
            let rounded = value.rounded()
            if abs(value - rounded) < 0.05 {
                return "\(symbol)\(Int(rounded))"
            }
            return String(format: "%@%.1f", symbol, value)
        } else if value >= 0.01 {
            let tenths = (value * 10).rounded() / 10
            if abs(value - tenths) < 0.005 {
                return abs(value - value.rounded()) < 0.005
                    ? "\(symbol)\(Int(value.rounded()))"
                    : String(format: "%@%.1f", symbol, value)
            }
            return String(format: "%@%.2f", symbol, value)
        }
        return "\(symbol)0"
    }

    private func formatCompactCount(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            let m = value / 1_000_000
            return m >= 100 ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        } else if value >= 1_000 {
            let k = value / 1_000
            return k >= 100 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        }
        return "\(Int(value.rounded()))"
    }

    private func formatCompactCurrency(_ value: Double, symbol: String) -> String {
        if value >= 1000 {
            return String(format: "%@%.1fK", symbol, value / 1000)
        } else if value >= 100 {
            return String(format: "%@%.0f", symbol, value)
        } else if value >= 10 {
            return String(format: "%@%.1f", symbol, value)
        } else if value >= 0.01 {
            return String(format: "%@%.2f", symbol, value)
        }
        return String(format: "%@0", symbol)
    }

    private func niceUpperBound(_ maxValue: Double) -> Double {
        guard maxValue > 0 else { return 1 }
        let padded = maxValue * 1.12
        let magnitude = pow(10, floor(log10(padded)))
        let normalized = padded / magnitude
        let step: Double
        if normalized <= 1.2 {
            step = 1.2
        } else if normalized <= 1.5 {
            step = 1.5
        } else if normalized <= 2.0 {
            step = 2.0
        } else if normalized <= 2.5 {
            step = 2.5
        } else if normalized <= 3.0 {
            step = 3.0
        } else if normalized <= 4.0 {
            step = 4.0
        } else if normalized <= 5.0 {
            step = 5.0
        } else if normalized <= 6.0 {
            step = 6.0
        } else if normalized <= 8.0 {
            step = 8.0
        } else {
            step = 10.0
        }
        return step * magnitude
    }
}

// MARK: - Reusable Ring Gauges & UI Components

private struct WidgetRingGroupGauge: View {
    let page: AIUsageWidgetProviderPage
    let group: AIUsageWidgetRingGroup
    let size: CGFloat
    let outerLineWidth: CGFloat
    let innerLineWidth: CGFloat
    let ringGap: CGFloat
    let showRemaining: Bool
    let showCenterSubtitle: Bool

    var body: some View {
        let outerPct = group.outerWindow.displayPercent(showRemaining: showRemaining)
        let outerProgress = normalizedTrim(group.outerWindow.ringProgress(showRemaining: showRemaining))
        let outerColor = page.outerRingColor(for: group.outerWindow)
        let innerSize = max(12, size - (outerLineWidth + ringGap) * 2)

        ZStack {
            // Outer Track
            Circle()
                .stroke(Color.primary.opacity(0.11), lineWidth: outerLineWidth)
                .frame(width: size, height: size)

            // Outer Progress
            Circle()
                .trim(from: 0, to: outerProgress)
                .stroke(
                    outerColor,
                    style: StrokeStyle(lineWidth: outerLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
                .widgetAccentable()

            if let inner = group.innerWindow {
                let innerProgress = normalizedTrim(inner.ringProgress(showRemaining: showRemaining))
                let innerColor = page.innerRingColor(for: inner)

                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: innerLineWidth)
                    .frame(width: innerSize, height: innerSize)

                Circle()
                    .trim(from: 0, to: innerProgress)
                    .stroke(
                        innerColor,
                        style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: innerSize, height: innerSize)
                    .widgetAccentable()
            }

            // Center numeric percentage
            VStack(spacing: 0) {
                Text("\(Int(outerPct.rounded()))%")
                    .font(.system(
                        size: centerFontSize,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                if showCenterSubtitle {
                    Text(showRemaining ? "left" : "used")
                        .font(.system(size: size >= 96 ? 10 : 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: group.isDual ? innerSize - innerLineWidth * 1.4 : size - outerLineWidth * 2.2)
        }
        .frame(width: size, height: size)
    }

    private var centerFontSize: CGFloat {
        if size >= 136 { return 28 }
        if size >= 100 { return 21 }
        if size >= 80 { return 16.5 }
        if size >= 68 { return 14.5 }
        if size >= 62 { return 13 }
        if size >= 52 { return 11.5 }
        return 9.5
    }

    private func normalizedTrim(_ value: Double) -> CGFloat {
        let clamped = min(1.0, max(0.0, value))
        if clamped > 0 && clamped < 0.03 { return 0.03 }
        return CGFloat(clamped)
    }
}

private struct WindowMetricRow: View {
    let window: AIUsageWidgetWindow
    let dotColor: Color
    let showRemaining: Bool
    let referenceDate: Date

    var body: some View {
        let pct = window.displayPercent(showRemaining: showRemaining)
        let fraction = min(1.0, max(0.0, pct / 100.0))

        VStack(alignment: .leading, spacing: 3.5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .widgetAccentable()

                Text(window.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let reset = window.resetCountdownText(referenceDate: referenceDate) {
                    Text(reset)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(dotColor)
                        .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * fraction))
                        .widgetAccentable()
                }
            }
            .frame(height: 4)
        }
    }
}

private struct ProviderHeaderBadge: View {
    let page: AIUsageWidgetProviderPage
    let iconSize: CGFloat
    let boxSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: boxSize * 0.28, style: .continuous)
                .fill(page.accentColor.opacity(0.18))
            WidgetProviderBrandIcon(
                iconAssetName: page.iconAssetName,
                symbolName: page.symbolName,
                size: iconSize
            )
            .foregroundStyle(page.accentColor)
            .widgetAccentable()
        }
        .frame(width: boxSize, height: boxSize)
    }
}

private struct PaginationControlPill: View {
    let pageIndex: Int
    let totalPages: Int
    let familyKey: String

    var body: some View {
        HStack(spacing: 2) {
            Button(intent: AIUsageWidgetTurnPageIntent(step: -1, familyKey: familyKey)) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(pageIndex + 1)/\(totalPages)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 22)

            Button(intent: AIUsageWidgetTurnPageIntent(step: 1, familyKey: familyKey)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 3)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

private struct PageDotsBar: View {
    let providers: [AIUsageWidgetProviderPage]
    let activeIndex: Int
    let activeColor: Color
    let familyKey: String
    let interactive: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { idx, item in
                let isActive = idx == activeIndex
                let dot = Capsule()
                    .fill(isActive ? activeColor : Color.primary.opacity(0.20))
                    .frame(width: isActive ? 14 : 5, height: 5)
                    .widgetAccentable()

                if interactive {
                    Button(intent: AIUsageWidgetSelectProviderIntent(providerID: item.id, familyKey: familyKey)) {
                        dot
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    dot
                }
            }
        }
    }
}

private struct LargeProviderSwitcherBar: View {
    let providers: [AIUsageWidgetProviderPage]
    let activeID: String
    let familyKey: String

    var body: some View {
        let compactMode = providers.count > 4
        HStack(spacing: 5) {
            ForEach(providers.prefix(6)) { item in
                let isActive = item.id == activeID
                Button(intent: AIUsageWidgetSelectProviderIntent(providerID: item.id, familyKey: familyKey)) {
                    HStack(spacing: 4) {
                        WidgetProviderBrandIcon(
                            iconAssetName: item.iconAssetName,
                            symbolName: item.symbolName,
                            size: 10.5
                        )
                        .foregroundStyle(isActive ? item.accentColor : .secondary)
                        .widgetAccentable()

                        if !compactMode || isActive {
                            Text(item.shortName)
                                .font(.system(size: 9.5, weight: isActive ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, compactMode && !isActive ? 7 : 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: compactMode && !isActive ? nil : .infinity)
                    .background(
                        Capsule()
                            .fill(isActive ? item.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                            .overlay {
                                if isActive {
                                    Capsule()
                                        .strokeBorder(item.accentColor.opacity(0.45), lineWidth: 0.8)
                                }
                            }
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ProviderEmptyDataView: View {
    let page: AIUsageWidgetProviderPage
    let compact: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(page.accentColor.opacity(0.28), style: StrokeStyle(lineWidth: 4, dash: [4, 4]))
                    .frame(width: compact ? 52 : 64, height: compact ? 52 : 64)
                WidgetProviderBrandIcon(
                    iconAssetName: page.iconAssetName,
                    symbolName: page.symbolName,
                    size: compact ? 20 : 24
                )
                .foregroundStyle(page.accentColor.opacity(0.85))
                .widgetAccentable()
            }

            Text(page.errorMessage ?? page.statusNote ?? "Waiting for data…")
                .font(.system(size: compact ? 9.5 : 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
    }
}

private struct EmptyProvidersWidgetView: View {
    let family: WidgetFamily

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 5)
                    .frame(width: family == .systemSmall ? 46 : 56, height: family == .systemSmall ? 46 : 56)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: family == .systemSmall ? 18 : 22, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text("No AI Providers")
                .font(.system(size: family == .systemSmall ? 12 : 14, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("Enable AI providers in PowerNotch Settings to see usage rings here.")
                .font(.system(size: family == .systemSmall ? 9.5 : 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum RelativeTimeFormatter {
    static func short(from date: Date, now: Date) -> String {
        let sec = max(0, Int(now.timeIntervalSince(date)))
        if sec < 60 { return "just now" }
        let min = sec / 60
        if min < 60 { return "\(min)m ago" }
        let hrs = min / 60
        if hrs < 24 { return "\(hrs)h ago" }
        return "\(hrs / 24)d ago"
    }
}

#if DEBUG
private enum AIUsageWidgetPreviewFixtures {
    static let baseDate = Date()

    static func makeDailyHistory(
        days: Int = 30,
        referenceDate: Date,
        values: [(tokens: Int64, cost: Double, requests: Int)]
    ) -> [AIUsageWidgetDailyPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"

        return (0..<days).reversed().enumerated().compactMap { idx, offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let sample = values[idx % values.count]
            return AIUsageWidgetDailyPoint(
                dayKey: df.string(from: date),
                tokens: sample.tokens,
                cost: sample.cost,
                requests: sample.requests
            )
        }
    }

    static func makeHourlyHistory(referenceDate: Date) -> [AIUsageWidgetDailyPoint] {
        let cal = Calendar.current
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd'T'HH"

        return (0..<24).reversed().enumerated().compactMap { idx, offset in
            guard let date = cal.date(byAdding: .hour, value: -offset, to: referenceDate) else { return nil }
            let wave = max(0.05, 0.45 + 0.4 * sin(Double(idx) * 0.42))
            return AIUsageWidgetDailyPoint(
                dayKey: df.string(from: date),
                tokens: Int64((1_800_000 * wave).rounded()),
                cost: (1.9 * wave * 100).rounded() / 100,
                requests: max(1, Int((42 * wave).rounded()))
            )
        }
    }

    static func makeProviders(now: Date) -> [AIUsageWidgetProviderPage] {
        let antigravityDaily = makeDailyHistory(
            days: 30,
            referenceDate: now,
            values: [
                (22_000_000, 12.4, 175),
                (38_000_000, 34.2, 290),
                (41_000_000, 40.0, 320),
                (31_000_000, 18.6, 240),
                (18_000_000, 6.2, 160),
                (10_000_000, 2.32, 95),
                (4_000_000, 0.28, 20)
            ]
        )
        let last7: [(Int64, Double, Int)] = [
            (12_000_000, 7.5, 110),
            (34_000_000, 26.2, 260),
            (36_000_000, 22.0, 250),
            (45_000_000, 40.0, 340),
            (20_000_000, 11.4, 180),
            (14_000_000, 6.62, 130),
            (3_000_000, 0.28, 30)
        ]
        let agHistory = Array(antigravityDaily.dropLast(7)) + makeDailyHistory(days: 7, referenceDate: now, values: last7)

        let ag2Pool = AIUsageWidgetProviderPage(
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
            planName: "Quota Pools",
            accountLabel: nil,
            sourceLabel: "agy-cli",
            statusNote: nil,
            errorMessage: nil,
            updatedAt: now,
            ringGroups: [
                AIUsageWidgetRingGroup(
                    id: "dual_gemini",
                    label: "Gemini",
                    outerWindow: AIUsageWidgetWindow(
                        id: "ag_gemini_5h",
                        label: "Gemini 5h",
                        usedPercent: 9,
                        detailText: nil,
                        resetAt: now.addingTimeInterval(3 * 3600),
                        isEstimated: false
                    ),
                    innerWindow: AIUsageWidgetWindow(
                        id: "ag_gemini_7d",
                        label: "Gemini 7d",
                        usedPercent: 4,
                        detailText: nil,
                        resetAt: now.addingTimeInterval(4 * 86400),
                        isEstimated: false
                    )
                ),
                AIUsageWidgetRingGroup(
                    id: "dual_claude_gpt",
                    label: "Claude/GPT",
                    outerWindow: AIUsageWidgetWindow(
                        id: "ag_claude_5h",
                        label: "Claude/GPT 5h",
                        usedPercent: 0,
                        detailText: nil,
                        resetAt: now.addingTimeInterval(4 * 3600),
                        isEstimated: false
                    ),
                    innerWindow: AIUsageWidgetWindow(
                        id: "ag_claude_7d",
                        label: "Claude/GPT 7d",
                        usedPercent: 22,
                        detailText: nil,
                        resetAt: now.addingTimeInterval(5 * 86400),
                        isEstimated: false
                    )
                )
            ],
            balance: nil,
            dailyHistory: agHistory,
            hourlyHistory: makeHourlyHistory(referenceDate: now),
            costCurrencySymbol: "≈$"
        )

        let claude1Pool = AIUsageWidgetProviderPage(
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
            accountLabel: "user@example.com",
            sourceLabel: "oauth",
            statusNote: nil,
            errorMessage: nil,
            updatedAt: now,
            ringGroups: [
                AIUsageWidgetRingGroup(
                    id: "dual_default",
                    label: "All",
                    outerWindow: AIUsageWidgetWindow(
                        id: "claude_5h",
                        label: "5-Hour Session",
                        usedPercent: 34,
                        detailText: nil,
                        resetAt: now.addingTimeInterval(2 * 3600 + 18 * 60),
                        isEstimated: false
                    ),
                    innerWindow: AIUsageWidgetWindow(
                        id: "claude_7d",
                        label: "Weekly All Models",
                        usedPercent: 52,
                        detailText: nil,
                        resetAt: now.addingTimeInterval(3 * 86400 + 6 * 3600),
                        isEstimated: false
                    )
                )
            ],
            balance: AIUsageWidgetBalance(
                currency: "USD",
                remaining: 18.40,
                usedThisPeriod: 11.60,
                limit: 30.00,
                periodLabel: "Extra Usage",
                formattedRemaining: "$18.40",
                compactFormattedRemaining: "$18.4",
                formattedBreakdown: "$18.40 / $30.00"
            ),
            dailyHistory: makeDailyHistory(
                days: 30,
                referenceDate: now,
                values: [(14_000_000, 4.2, 90), (21_500_000, 6.8, 125), (9_500_000, 2.9, 64), (17_000_000, 5.1, 102)]
            ),
            hourlyHistory: makeHourlyHistory(referenceDate: now),
            costCurrencySymbol: "≈$"
        )

        let ag3Pool = AIUsageWidgetProviderPage(
            id: "antigravity3",
            displayName: "Antigravity",
            shortName: "Agy-3",
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
            updatedAt: now,
            ringGroups: AIUsageWidgetPayload.sample.providers[1].ringGroups,
            balance: nil,
            dailyHistory: agHistory,
            hourlyHistory: makeHourlyHistory(referenceDate: now),
            costCurrencySymbol: "≈$"
        )

        let fourPool = AIUsageWidgetProviderPage(
            id: "cursor4",
            displayName: "Cursor Enterprise",
            shortName: "Cursor",
            iconAssetName: "ProviderIcon-cursor",
            symbolName: "cursorarrow.rays",
            accentRed: 0.32,
            accentGreen: 0.64,
            accentBlue: 0.96,
            innerRed: 0.36,
            innerGreen: 0.78,
            innerBlue: 1.0,
            planName: "Teams",
            accountLabel: nil,
            sourceLabel: "api",
            statusNote: nil,
            errorMessage: nil,
            updatedAt: now,
            ringGroups: [
                AIUsageWidgetRingGroup(
                    id: "p1",
                    label: "Sonnet",
                    outerWindow: AIUsageWidgetWindow(id: "w1", label: "5h", usedPercent: 28, detailText: nil, resetAt: now.addingTimeInterval(3600), isEstimated: false),
                    innerWindow: AIUsageWidgetWindow(id: "w1i", label: "7d", usedPercent: 45, detailText: nil, resetAt: now.addingTimeInterval(3 * 86400), isEstimated: false)
                ),
                AIUsageWidgetRingGroup(
                    id: "p2",
                    label: "Opus",
                    outerWindow: AIUsageWidgetWindow(id: "w2", label: "5h", usedPercent: 62, detailText: nil, resetAt: now.addingTimeInterval(3600), isEstimated: false),
                    innerWindow: AIUsageWidgetWindow(id: "w2i", label: "7d", usedPercent: 71, detailText: nil, resetAt: now.addingTimeInterval(3 * 86400), isEstimated: false)
                ),
                AIUsageWidgetRingGroup(
                    id: "p3",
                    label: "GPT-5",
                    outerWindow: AIUsageWidgetWindow(id: "w3", label: "5h", usedPercent: 14, detailText: nil, resetAt: now.addingTimeInterval(3600), isEstimated: false),
                    innerWindow: AIUsageWidgetWindow(id: "w3i", label: "7d", usedPercent: 19, detailText: nil, resetAt: now.addingTimeInterval(3 * 86400), isEstimated: false)
                ),
                AIUsageWidgetRingGroup(
                    id: "p4",
                    label: "Fast",
                    outerWindow: AIUsageWidgetWindow(id: "w4", label: "5h", usedPercent: 5, detailText: nil, resetAt: now.addingTimeInterval(3600), isEstimated: false),
                    innerWindow: AIUsageWidgetWindow(id: "w4i", label: "7d", usedPercent: 12, detailText: nil, resetAt: now.addingTimeInterval(3 * 86400), isEstimated: false)
                )
            ],
            balance: nil,
            dailyHistory: agHistory,
            hourlyHistory: makeHourlyHistory(referenceDate: now),
            costCurrencySymbol: "$"
        )

        let balanceOnly = AIUsageWidgetProviderPage(
            id: "openrouter",
            displayName: "OpenRouter",
            shortName: "OpenRouter",
            iconAssetName: "ProviderIcon-openrouter",
            symbolName: "network",
            accentRed: 0.64,
            accentGreen: 0.44,
            accentBlue: 0.96,
            innerRed: 0.72,
            innerGreen: 0.56,
            innerBlue: 1.0,
            planName: nil,
            accountLabel: nil,
            sourceLabel: "api-key",
            statusNote: nil,
            errorMessage: nil,
            updatedAt: now,
            ringGroups: [],
            balance: AIUsageWidgetBalance(
                currency: "USD",
                remaining: 42.85,
                usedThisPeriod: 17.15,
                limit: 60.00,
                periodLabel: "Prepaid Wallet",
                formattedRemaining: "$42.85",
                compactFormattedRemaining: "$42.9",
                formattedBreakdown: "$17.15 used · $60.00 cap"
            ),
            dailyHistory: makeDailyHistory(
                days: 30,
                referenceDate: now,
                values: [(4_500_000, 1.85, 45), (8_200_000, 3.40, 82), (2_100_000, 0.92, 24), (6_000_000, 2.55, 63)]
            ),
            hourlyHistory: makeHourlyHistory(referenceDate: now),
            costCurrencySymbol: "$"
        )

        return [ag2Pool, claude1Pool, ag3Pool, fourPool, balanceOnly]
    }

    static func makeLargePayload(now: Date = baseDate) -> AIUsageWidgetPayload {
        AIUsageWidgetPayload(
            schemaVersion: AIUsageWidgetSharedConstants.currentSchemaVersion,
            updatedAt: now,
            showRemainingPercent: true,
            hideAccountEmails: false,
            providers: makeProviders(now: now)
        )
    }

    static func makeEmptyPage(now: Date = baseDate) -> AIUsageWidgetProviderPage {
        AIUsageWidgetProviderPage(
            id: "empty",
            displayName: "DeepSeek",
            shortName: "DeepSeek",
            iconAssetName: "ProviderIcon-deepseek",
            symbolName: "magnifyingglass.circle",
            accentRed: 0.30,
            accentGreen: 0.56,
            accentBlue: 0.96,
            innerRed: 0.36,
            innerGreen: 0.78,
            innerBlue: 1.0,
            planName: nil,
            accountLabel: nil,
            sourceLabel: "api",
            statusNote: "Waiting for next refresh cycle…",
            errorMessage: nil,
            updatedAt: now,
            ringGroups: [],
            balance: nil,
            dailyHistory: [],
            hourlyHistory: [],
            costCurrencySymbol: "$"
        )
    }
}

private struct WidgetCanvasCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let accentColor: Color
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                WidgetAmbientBackground(
                    accentColor: accentColor,
                    renderingMode: .fullColor,
                    colorScheme: colorScheme
                )
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .preferredColorScheme(.dark)
    }
}

private struct LargeWidgetInteractivePreview: View {
    enum Scenario: String, CaseIterable, Identifiable {
        case twoPools = "2 Pools"
        case onePool = "1 Pool"
        case threePools = "3 Pools"
        case fourPools = "4 Pools"
        case balance = "Balance"
        case empty = "Empty"

        var id: String { rawValue }
    }

    @State private var scenario: Scenario = .twoPools
    @State private var range: AIUsageChartRange = .week
    @State private var metric: AIUsageChartMetric = .cost

    private let now = AIUsageWidgetPreviewFixtures.baseDate

    private var providers: [AIUsageWidgetProviderPage] {
        AIUsageWidgetPreviewFixtures.makeProviders(now: now)
    }

    private var activeSelection: (page: AIUsageWidgetProviderPage, all: [AIUsageWidgetProviderPage], index: Int) {
        let baseProviders = providers
        switch scenario {
        case .twoPools:
            return (baseProviders[0], baseProviders, 1)
        case .onePool:
            return (baseProviders[1], baseProviders, 0)
        case .threePools:
            return (baseProviders[2], baseProviders, 2)
        case .fourPools:
            return (baseProviders[3], baseProviders, 3)
        case .balance:
            return (baseProviders[4], baseProviders, 4)
        case .empty:
            let emptyPage = AIUsageWidgetPreviewFixtures.makeEmptyPage(now: now)
            return (emptyPage, [emptyPage] + Array(baseProviders.dropFirst()), 0)
        }
    }

    var body: some View {
        let selection = activeSelection
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Scenario.allCases) { item in
                    let isSelected = item == scenario
                    Button {
                        scenario = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? selection.page.accentColor.opacity(0.24) : Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Picker("Range", selection: $range) {
                    ForEach(AIUsageChartRange.allCases) { item in
                        Text(item.shortLabel).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Picker("Metric", selection: $metric) {
                    ForEach(AIUsageChartMetric.allCases) { item in
                        Text(item.shortLabel).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .frame(width: 328)

            WidgetCanvasCard(accentColor: selection.page.accentColor, width: 328, height: 326) {
                LargeProviderPageView(
                    page: selection.page,
                    allProviders: selection.all,
                    pageIndex: selection.index,
                    totalPages: selection.all.count,
                    familyKey: "large",
                    showRemaining: true,
                    selectedChartMetric: metric,
                    selectedChartRange: range,
                    updatedAt: now,
                    referenceDate: now
                )
            }
        }
        .padding(16)
        .background(Color(red: 0.05, green: 0.06, blue: 0.07))
        .preferredColorScheme(.dark)
    }
}

@MainActor
private func makeLargePreviewCard(
    providerIndex: Int,
    pageIndex: Int,
    metric: AIUsageChartMetric,
    range: AIUsageChartRange
) -> some View {
    let now = AIUsageWidgetPreviewFixtures.baseDate
    let providers = AIUsageWidgetPreviewFixtures.makeProviders(now: now)
    let page = providers[providerIndex]
    return WidgetCanvasCard(accentColor: page.accentColor, width: 328, height: 326) {
        LargeProviderPageView(
            page: page,
            allProviders: providers,
            pageIndex: pageIndex,
            totalPages: providers.count,
            familyKey: "large",
            showRemaining: true,
            selectedChartMetric: metric,
            selectedChartRange: range,
            updatedAt: now,
            referenceDate: now
        )
    }
    .padding(16)
}

#Preview("Large · Interactive") {
    LargeWidgetInteractivePreview()
}

#Preview("Large · 2 Pools (7D Spend)") {
    makeLargePreviewCard(providerIndex: 0, pageIndex: 1, metric: .cost, range: .week)
}

#Preview("Large · 1 Pool + Balance") {
    makeLargePreviewCard(providerIndex: 1, pageIndex: 0, metric: .tokens, range: .month)
}

#Preview("Large · 3 Pools") {
    makeLargePreviewCard(providerIndex: 2, pageIndex: 2, metric: .cost, range: .week)
}

#Preview("Large · 4 Pools (1D)") {
    makeLargePreviewCard(providerIndex: 3, pageIndex: 3, metric: .requests, range: .day)
}

#Preview("Large · Balance Only") {
    makeLargePreviewCard(providerIndex: 4, pageIndex: 4, metric: .cost, range: .month)
}

#Preview("Medium & Small") {
    let now = AIUsageWidgetPreviewFixtures.baseDate
    let providers = AIUsageWidgetPreviewFixtures.makeProviders(now: now)
    let claude = providers[1]
    let antigravity = providers[0]

    return VStack(spacing: 14) {
        WidgetCanvasCard(accentColor: antigravity.accentColor, width: 328, height: 158) {
            MediumProviderPageView(
                page: antigravity,
                allProviders: providers,
                pageIndex: 0,
                totalPages: providers.count,
                familyKey: "medium",
                showRemaining: true,
                updatedAt: now,
                referenceDate: now
            )
        }

        WidgetCanvasCard(accentColor: claude.accentColor, width: 158, height: 158) {
            SmallProviderPageView(
                page: claude,
                allProviders: providers,
                pageIndex: 1,
                totalPages: providers.count,
                familyKey: "small",
                showRemaining: true,
                referenceDate: now
            )
        }
    }
    .padding(16)
}
#endif
