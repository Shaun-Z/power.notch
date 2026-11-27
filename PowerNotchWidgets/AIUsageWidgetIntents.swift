//
//  AIUsageWidgetIntents.swift
//  PowerNotchWidgets
//
//  Interactive AppIntents for flipping provider pages, switching 30-day chart metrics,
//  and requesting background refresh directly from desktop widgets.
//

import AppIntents
import Foundation
import WidgetKit

struct AIUsageWidgetTurnPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn AI Usage Page"
    static var description = IntentDescription("Switch to the next or previous configured AI provider in the desktop widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Step")
    var step: Int

    @Parameter(title: "Widget Family")
    var familyKey: String

    init() {
        self.step = 1
        self.familyKey = "medium"
    }

    init(step: Int, familyKey: String) {
        self.step = step
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        AIUsageWidgetStore.turnPage(step: step, familyKey: familyKey)
        WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetConstants.widgetKind)
        return .result()
    }
}

struct AIUsageWidgetSelectProviderIntent: AppIntent {
    static var title: LocalizedStringResource = "Select AI Provider Page"
    static var description = IntentDescription("Jump directly to a specific configured AI provider page in the desktop widget.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Provider ID")
    var providerID: String

    @Parameter(title: "Widget Family")
    var familyKey: String

    init() {
        self.providerID = ""
        self.familyKey = "medium"
    }

    init(providerID: String, familyKey: String) {
        self.providerID = providerID
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        AIUsageWidgetStore.selectProvider(id: providerID, familyKey: familyKey)
        WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetConstants.widgetKind)
        return .result()
    }
}

struct AIUsageWidgetSelectChartMetricIntent: AppIntent {
    static var title: LocalizedStringResource = "Select 30-Day Chart Metric"
    static var description = IntentDescription("Switch the 30-day usage line chart between Tokens, Spend, and Requests.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Metric")
    var metricRaw: String

    init() {
        self.metricRaw = AIUsageChartMetric.tokens.rawValue
    }

    init(metric: AIUsageChartMetric) {
        self.metricRaw = metric.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let metric = AIUsageChartMetric(rawValue: metricRaw) {
            AIUsageWidgetStore.setSelectedChartMetric(metric)
            WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetConstants.widgetKind)
        }
        return .result()
    }
}

struct AIUsageWidgetSelectChartRangeIntent: AppIntent {
    static var title: LocalizedStringResource = "Select Trend Range"
    static var description = IntentDescription("Switch the usage line chart between 24 hours, 7 days, and 30 days.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Range")
    var rangeRaw: String

    init() {
        self.rangeRaw = AIUsageChartRange.month.rawValue
    }

    init(range: AIUsageChartRange) {
        self.rangeRaw = range.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let range = AIUsageChartRange(rawValue: rangeRaw) {
            AIUsageWidgetStore.setSelectedChartRange(range)
            WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetConstants.widgetKind)
        }
        return .result()
    }
}

struct AIUsageWidgetRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh AI Usage"
    static var description = IntentDescription("Request PowerNotch to refresh AI usage data.")
    static var isDiscoverable: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            AIUsageWidgetConstants.refreshRequestNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        #if WIDGET_PREVIEW_HOST
        Task { @MainActor in
            NotificationCenter.default.post(
                name: AIUsageWidgetStore.previewRefreshRequestedNotification,
                object: nil
            )
        }
        #endif
        WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetConstants.widgetKind)
        return .result()
    }
}
