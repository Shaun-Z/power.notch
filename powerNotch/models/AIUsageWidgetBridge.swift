//
//  AIUsageWidgetBridge.swift
//  powerNotch
//
//  Shared App Group snapshot writer & notification bridge between PowerNotch and PowerNotchWidgetsExtension.
//

import AppKit
import Foundation
import SwiftUI
import WidgetKit

enum AIUsageWidgetBridgeConstants {
    static let appGroupID = "877W5ZP5WY.com.powernotch.app"
    static let widgetKind = "com.powernotch.app.aiUsageWidget"
    static let payloadFileName = "ai-usage-widget-state.json"
    static let refreshRequestNotification = Notification.Name("com.powernotch.app.aiUsage.requestRefresh")
}

struct AIUsageWidgetPayload: Codable, Sendable {
    let schemaVersion: Int
    let updatedAt: Date
    let showRemainingPercent: Bool
    let hideAccountEmails: Bool
    let providers: [AIUsageWidgetProviderPage]
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
}

struct AIUsageWidgetRingGroup: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let outerWindow: AIUsageWidgetWindow
    let innerWindow: AIUsageWidgetWindow?
}

struct AIUsageWidgetWindow: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
    let detailText: String?
    let resetAt: Date?
    let isEstimated: Bool
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

enum AIUsageWidgetSync {
    private static func containerFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AIUsageWidgetBridgeConstants.appGroupID)?
            .appendingPathComponent(AIUsageWidgetBridgeConstants.payloadFileName, isDirectory: false)
    }

    static func sync(
        enabledProviders: [AIProviderID],
        snapshots: [AIProviderID: AIProviderSnapshot],
        dailyHistories: [AIProviderID: [AIUsageWidgetDailyPoint]] = [:],
        showRemainingPercent: Bool,
        hideAccountEmails: Bool
    ) {
        let pages: [AIUsageWidgetProviderPage] = enabledProviders.map { provider in
            let snap = snapshots[provider]
            let accentRGB = rgbComponents(for: provider.accentColor)
            let innerRGB = innerRGBComponents(for: provider)

            let groups: [AIUsageWidgetRingGroup] = {
                guard let windows = snap?.windows, !windows.isEmpty else { return [] }
                return AIUsageRingGroup.build(from: windows).map { group in
                    AIUsageWidgetRingGroup(
                        id: group.id,
                        label: group.label,
                        outerWindow: AIUsageWidgetWindow(
                            id: group.outerWindow.id,
                            label: group.outerWindow.label,
                            usedPercent: group.outerWindow.clampedUsedPercent,
                            detailText: group.outerWindow.detailText,
                            resetAt: group.outerWindow.resetAt,
                            isEstimated: group.outerWindow.isEstimated
                        ),
                        innerWindow: group.innerWindow.map { inner in
                            AIUsageWidgetWindow(
                                id: inner.id,
                                label: inner.label,
                                usedPercent: inner.clampedUsedPercent,
                                detailText: inner.detailText,
                                resetAt: inner.resetAt,
                                isEstimated: inner.isEstimated
                            )
                        }
                    )
                }
            }()

            let widgetBalance: AIUsageWidgetBalance? = snap?.balance.map { bal in
                AIUsageWidgetBalance(
                    currency: bal.currency,
                    remaining: bal.remaining,
                    usedThisPeriod: bal.usedThisPeriod,
                    limit: bal.limit,
                    periodLabel: bal.periodLabel,
                    formattedRemaining: bal.formattedRemaining,
                    compactFormattedRemaining: bal.compactFormattedRemaining,
                    formattedBreakdown: bal.formattedBreakdown
                )
            }

            let history = dailyHistories[provider] ?? []
            let currencySymbol = history.compactMap(\.selectedCost).first?.chartCurrencyPrefix ?? ""

            return AIUsageWidgetProviderPage(
                id: provider.rawValue,
                displayName: provider.displayName,
                shortName: provider.shortName,
                iconAssetName: provider.iconAssetName,
                symbolName: provider.symbolName,
                accentRed: accentRGB.r,
                accentGreen: accentRGB.g,
                accentBlue: accentRGB.b,
                innerRed: innerRGB.r,
                innerGreen: innerRGB.g,
                innerBlue: innerRGB.b,
                planName: snap?.planName,
                accountLabel: hideAccountEmails ? nil : snap?.accountLabel,
                sourceLabel: snap?.sourceLabel,
                statusNote: snap?.statusNote,
                errorMessage: snap?.errorMessage,
                updatedAt: snap?.updatedAt,
                ringGroups: groups,
                balance: widgetBalance,
                dailyHistory: history,
                costCurrencySymbol: currencySymbol
            )
        }

        let payload = AIUsageWidgetPayload(
            schemaVersion: 3,
            updatedAt: Date(),
            showRemainingPercent: showRemainingPercent,
            hideAccountEmails: hideAccountEmails,
            providers: pages
        )

        guard let fileURL = containerFileURL() else {
            WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetBridgeConstants.widgetKind)
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: widget will keep last good snapshot if container write fails
        }

        WidgetCenter.shared.reloadTimelines(ofKind: AIUsageWidgetBridgeConstants.widgetKind)
    }

    private static func rgbComponents(for color: SwiftUI.Color) -> (r: Double, g: Double, b: Double) {
        if let nsColor = NSColor(color).usingColorSpace(.sRGB) {
            return (
                r: Double(nsColor.redComponent),
                g: Double(nsColor.greenComponent),
                b: Double(nsColor.blueComponent)
            )
        }
        return (0.36, 0.62, 0.98)
    }

    private static func innerRGBComponents(for provider: AIProviderID) -> (r: Double, g: Double, b: Double) {
        switch provider {
        case .copilot, .deepseek, .zai, .openrouter, .opencode:
            return (0.72, 0.56, 1.0)
        default:
            return (0.36, 0.78, 1.0)
        }
    }
}
