//
//  AIUsageWidgetModels.swift
//  PowerNotchWidgets
//
//  Shared data contract and App Group / widget-local persistence for desktop widgets.
//

import AppKit
import Foundation
import SwiftUI

typealias AIUsageWidgetConstants = AIUsageWidgetSharedConstants

enum AIUsageChartMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens
    case cost
    case requests

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Spend"
        case .requests: return "Reqs"
        }
    }

    var systemImage: String {
        switch self {
        case .tokens: return "cpu"
        case .cost: return "creditcard"
        case .requests: return "bolt.fill"
        }
    }

    func value(for point: AIUsageWidgetDailyPoint) -> Double {
        switch self {
        case .tokens: return Double(max(0, point.tokens))
        case .cost: return max(0, point.cost)
        case .requests: return Double(max(0, point.requests))
        }
    }
}

/// The window the trend card plots. 1D needs hour buckets, which only usage logs can fill.
enum AIUsageChartRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .day: return "1D"
        case .week: return "7D"
        case .month: return "30D"
        }
    }

    var title: String {
        switch self {
        case .day: return "24-Hour Trend"
        case .week: return "7-Day Trend"
        case .month: return "30-Day Trend"
        }
    }

    var totalLabel: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    func points(for page: AIUsageWidgetProviderPage) -> [AIUsageWidgetDailyPoint] {
        switch self {
        case .day: return Array(page.hourlyHistory.suffix(24))
        case .week: return Array(page.dailyHistory.suffix(7))
        case .month: return Array(page.dailyHistory.suffix(30))
        }
    }
}

extension AIUsageWidgetProviderPage {
    var accentColor: Color {
        Color(red: accentRed, green: accentGreen, blue: accentBlue)
    }

    var baseInnerColor: Color {
        Color(red: innerRed, green: innerGreen, blue: innerBlue)
    }

    func outerRingColor(for window: AIUsageWidgetWindow) -> Color {
        if window.clampedUsedPercent >= 95 { return .red }
        if window.clampedUsedPercent >= 80 { return .orange }
        return accentColor
    }

    func innerRingColor(for window: AIUsageWidgetWindow) -> Color {
        if window.clampedUsedPercent >= 95 { return .red }
        if window.clampedUsedPercent >= 80 { return .orange }
        return baseInnerColor
    }

}

// MARK: - App Group Store & Pagination State

enum AIUsageWidgetStore {
    private static let chartMetricKey = "aiUsageWidget.large.selectedChartMetric"
    private static let chartRangeKey = "aiUsageWidget.large.selectedChartRange"

    private static func payloadFileURL() -> URL? {
        AIUsageWidgetSharedConstants.payloadFileURL()
    }

    private static var defaults: UserDefaults {
        guard AIUsageWidgetSharedConstants.hasTeamPrefixedAppGroup() else { return .standard }
        return UserDefaults(suiteName: AIUsageWidgetConstants.appGroupID) ?? .standard
    }

    private static func pageKey(for familyKey: String) -> String {
        "aiUsageWidget.selectedProvider.\(familyKey)"
    }

    static func loadPayload() -> AIUsageWidgetPayload? {
        guard let url = payloadFileURL(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AIUsageWidgetPayload.self, from: data)
    }

    static func selectedProviderID(for familyKey: String) -> String? {
        defaults.string(forKey: pageKey(for: familyKey))
    }

    static func setSelectedProviderID(_ id: String, for familyKey: String) {
        defaults.set(id, forKey: pageKey(for: familyKey))
    }

    static func selectedChartMetric() -> AIUsageChartMetric {
        guard let raw = defaults.string(forKey: chartMetricKey),
              let metric = AIUsageChartMetric(rawValue: raw)
        else { return .tokens }
        return metric
    }

    static func setSelectedChartMetric(_ metric: AIUsageChartMetric) {
        defaults.set(metric.rawValue, forKey: chartMetricKey)
    }

    static func selectedChartRange() -> AIUsageChartRange {
        guard let raw = defaults.string(forKey: chartRangeKey),
              let range = AIUsageChartRange(rawValue: raw)
        else { return .month }
        return range
    }

    static func setSelectedChartRange(_ range: AIUsageChartRange) {
        defaults.set(range.rawValue, forKey: chartRangeKey)
    }

    static func resolvePage(
        in providers: [AIUsageWidgetProviderPage],
        familyKey: String
    ) -> (page: AIUsageWidgetProviderPage, index: Int, total: Int)? {
        guard !providers.isEmpty else { return nil }
        if let savedID = selectedProviderID(for: familyKey),
           let idx = providers.firstIndex(where: { $0.id == savedID })
        {
            return (providers[idx], idx, providers.count)
        }
        return (providers[0], 0, providers.count)
    }

    static func turnPage(step: Int, familyKey: String) {
        guard let payload = loadPayload(), !payload.providers.isEmpty else { return }
        let providers = payload.providers
        let currentIndex = resolvePage(in: providers, familyKey: familyKey)?.index ?? 0
        let count = providers.count
        let nextIndex = ((currentIndex + step) % count + count) % count
        setSelectedProviderID(providers[nextIndex].id, for: familyKey)
    }

    static func selectProvider(id: String, familyKey: String) {
        guard let payload = loadPayload(),
              payload.providers.contains(where: { $0.id == id })
        else { return }
        setSelectedProviderID(id, for: familyKey)
    }
}

struct WidgetProviderBrandIcon: View {
    let iconAssetName: String
    let symbolName: String
    let size: CGFloat

    var body: some View {
        Group {
            if NSImage(named: NSImage.Name(iconAssetName)) != nil {
                Image(iconAssetName)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbolName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}
