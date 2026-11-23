//
//  AIUsageWidgetModels.swift
//  PowerNotchWidgets
//
//  Shared data contract & App Group persistence for PowerNotch AI Usage desktop widgets.
//

import AppKit
import Foundation
import SwiftUI

enum AIUsageWidgetConstants {
    static let appGroupID = "877W5ZP5WY.com.powernotch.app"
    static let widgetKind = "com.powernotch.app.aiUsageWidget"
    static let payloadFileName = "ai-usage-widget-state.json"
    static let refreshRequestNotification = Notification.Name("com.powernotch.app.aiUsage.requestRefresh")
}

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

struct AIUsageWidgetDailyPoint: Codable, Identifiable, Sendable, Equatable {
    let dayKey: String      // "YYYY-MM-DD" in local timezone
    let tokens: Int64
    let cost: Double
    let requests: Int

    var id: String { dayKey }

    var shortDateLabel: String {
        // "YYYY-MM-DD" -> "MM/DD"
        let parts = dayKey.split(separator: "-")
        if parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) {
            return "\(m)/\(d)"
        }
        return dayKey
    }
}

struct AIUsageWidgetPayload: Codable, Sendable {
    let schemaVersion: Int
    let updatedAt: Date
    let showRemainingPercent: Bool
    let hideAccountEmails: Bool
    let providers: [AIUsageWidgetProviderPage]

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
        schemaVersion: 2,
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
        self.costCurrencySymbol = costCurrencySymbol
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, shortName, iconAssetName, symbolName
        case accentRed, accentGreen, accentBlue
        case innerRed, innerGreen, innerBlue
        case planName, accountLabel, sourceLabel, statusNote, errorMessage, updatedAt
        case ringGroups, balance, dailyHistory, costCurrencySymbol
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
        costCurrencySymbol = try c.decodeIfPresent(String.self, forKey: .costCurrencySymbol) ?? "$"
    }

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

    var isDual: Bool { innerWindow != nil }
}

struct AIUsageWidgetWindow: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
    let detailText: String?
    let resetAt: Date?
    let isEstimated: Bool

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
}

// MARK: - App Group Store & Pagination State

enum AIUsageWidgetStore {
    private static let chartMetricKey = "aiUsageWidget.large.selectedChartMetric"

    private static func payloadFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AIUsageWidgetConstants.appGroupID)?
            .appendingPathComponent(AIUsageWidgetConstants.payloadFileName, isDirectory: false)
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AIUsageWidgetConstants.appGroupID)
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
        defaults?.string(forKey: pageKey(for: familyKey))
    }

    static func setSelectedProviderID(_ id: String, for familyKey: String) {
        defaults?.set(id, forKey: pageKey(for: familyKey))
    }

    static func selectedChartMetric() -> AIUsageChartMetric {
        guard let raw = defaults?.string(forKey: chartMetricKey),
              let metric = AIUsageChartMetric(rawValue: raw)
        else { return .tokens }
        return metric
    }

    static func setSelectedChartMetric(_ metric: AIUsageChartMetric) {
        defaults?.set(metric.rawValue, forKey: chartMetricKey)
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
