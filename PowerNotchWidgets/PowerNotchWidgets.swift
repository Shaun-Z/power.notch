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
    let updatedAt: Date?
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Top bar
            HStack(alignment: .center, spacing: 8) {
                ProviderHeaderBadge(page: page, iconSize: 14, boxSize: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.displayName)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    HStack(spacing: 5) {
                        if let plan = page.planName, !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(page.accentColor)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(page.accentColor.opacity(0.16)))
                                .lineLimit(1)
                        } else if let src = page.sourceLabel, !src.isEmpty {
                            Text(src)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let updatedAt {
                            Text("Updated \(RelativeTimeFormatter.short(from: updatedAt, now: referenceDate))")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
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

            // Lower Section: 30-Day Tokens / Spend / Requests Line Chart
            Large30DayTrendCard(
                page: page,
                selectedMetric: selectedChartMetric,
                referenceDate: referenceDate
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Interactive Provider Selector Dock
            if totalPages > 1 {
                LargeProviderSwitcherBar(
                    providers: allProviders,
                    activeID: page.id,
                    familyKey: familyKey
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var largeUpperQuotaSection: some View {
        if page.ringGroups.count == 1, let group = page.ringGroups.first {
            HStack(spacing: 12) {
                WidgetRingGroupGauge(
                    page: page,
                    group: group,
                    size: 78,
                    outerLineWidth: 7.2,
                    innerLineWidth: 5.6,
                    ringGap: 3.6,
                    showRemaining: showRemaining,
                    showCenterSubtitle: true
                )

                VStack(alignment: .leading, spacing: 6) {
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
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(page.accentColor.opacity(0.14)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else if page.ringGroups.count > 1 {
            let visibleGroups = Array(page.ringGroups.prefix(4))
            let ringSize: CGFloat = visibleGroups.count == 2 ? 66 : (visibleGroups.count == 3 ? 60 : 50)
            HStack(spacing: visibleGroups.count <= 3 ? 10 : 6) {
                ForEach(visibleGroups) { group in
                    VStack(spacing: 3.5) {
                        WidgetRingGroupGauge(
                            page: page,
                            group: group,
                            size: ringSize,
                            outerLineWidth: visibleGroups.count <= 3 ? 5.8 : 4.8,
                            innerLineWidth: visibleGroups.count <= 3 ? 4.4 : 3.6,
                            ringGap: visibleGroups.count <= 3 ? 2.8 : 2.2,
                            showRemaining: showRemaining,
                            showCenterSubtitle: false
                        )

                        Text(group.label)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
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
                                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else if let balance = page.balance {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(balance.periodLabel ?? "Available Balance")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(balance.formattedRemaining)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } else {
            ProviderEmptyDataView(page: page, compact: true)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
        }
    }
}

// MARK: - Large Widget 30-Day Trend Line Chart Card

private struct Large30DayTrendCard: View {
    let page: AIUsageWidgetProviderPage
    let selectedMetric: AIUsageChartMetric
    let referenceDate: Date

    private struct IndexedPoint: Identifiable {
        let index: Int
        let dayKey: String
        let shortDateLabel: String
        let value: Double

        var id: Int { index }
    }

    private var resolvedHistory: [AIUsageWidgetDailyPoint] {
        if !page.dailyHistory.isEmpty {
            return Array(page.dailyHistory.suffix(30))
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

        VStack(alignment: .leading, spacing: 7) {
            // Card Header: "30D Trend" + active peak / today callout
            HStack(spacing: 6) {
                Text("30-Day Trend")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if hasData {
                    let todayVal = points.last?.value ?? 0
                    Text("Today \(formatMetricValue(todayVal, for: selectedMetric)) · Peak \(formatMetricValue(maxValue, for: selectedMetric))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Last 30 days")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }

            // 3 Interactive Metric Switcher Pills (Shows all 3 totals at once)
            HStack(spacing: 5) {
                ForEach(AIUsageChartMetric.allCases) { metric in
                    metricPill(for: metric)
                }
            }

            // Smooth 30-Day Line Chart
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
                        Text("No 30-day \(selectedMetric.shortLabel.lowercased()) yet")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    @ViewBuilder
    private func trendChartView(points: [IndexedPoint], maxValue: Double) -> some View {
        let yUpper = niceUpperBound(maxValue)
        let midIndex = points.count / 2
        let lastIndex = max(1, points.count - 1)
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
        .chartXScale(domain: 0...lastIndex)
        .chartYScale(domain: 0...yUpper)
        .chartXAxis {
            AxisMarks(values: [0, midIndex, lastIndex]) { value in
                if let idx = value.as(Int.self), idx >= 0, idx < points.count {
                    AxisValueLabel {
                        Text(idx == lastIndex ? "Today" : points[idx].shortDateLabel)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.85))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, yUpper * 0.5, yUpper]) { value in
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
        .widgetAccentable()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func metricPill(for metric: AIUsageChartMetric) -> some View {
        let isActive = metric == selectedMetric
        let tint = metricColor(for: metric)
        let totalText = formatted30DayTotal(for: metric)

        Button(intent: AIUsageWidgetSelectChartMetricIntent(metric: metric)) {
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 3.5) {
                    Circle()
                        .fill(isActive ? tint : tint.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .widgetAccentable()
                    Text(metric.shortLabel)
                        .font(.system(size: 9, weight: isActive ? .bold : .medium, design: .rounded))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }

                Text(totalText)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? tint.opacity(0.16) : Color.primary.opacity(0.05))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(tint.opacity(0.50), lineWidth: 0.85)
                        }
                    }
            )
        }
        .buttonStyle(.plain)
    }

    private func formatted30DayTotal(for metric: AIUsageChartMetric) -> String {
        switch metric {
        case .tokens:
            let t = page.total30dTokens
            return t > 0 ? formatCompactCount(Double(t)) : "—"
        case .cost:
            let c = page.total30dCost
            return c > 0.0001 ? formatCompactCurrency(c, symbol: page.costCurrencySymbol) : "—"
        case .requests:
            let r = page.total30dRequests
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
        return formatMetricValue(value, for: metric)
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
                            size: 11
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
                    .padding(.vertical, 5)
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
