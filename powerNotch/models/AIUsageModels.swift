//
//  AIUsageModels.swift
//  powerNotch
//
//  Unified AI Provider Usage & Quota models inspired by OpenCode (/usage), CodexBar, and paseo-usage-monitor.
//

import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Provider Registry

enum AIProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex = "codex"
    case claude = "claude"
    case antigravity = "antigravity"
    case copilot = "copilot"
    case cursor = "cursor"
    case opencode = "opencode"
    case mimo = "mimo"
    case openrouter = "openrouter"
    case deepseek = "deepseek"
    case zai = "zai"
    case kimi = "kimi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .mimo: return "Xiaomi MiMo"
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .zai: return "GLM / z.ai"
        case .kimi: return "Kimi"
        }
    }

    var shortName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .copilot: return "Copilot"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .mimo: return "MiMo"
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .zai: return "GLM"
        case .kimi: return "Kimi"
        }
    }

    var iconAssetName: String {
        "ProviderIcon-\(rawValue)"
    }

    var symbolName: String {
        switch self {
        case .codex: return "terminal.fill"
        case .claude: return "sparkles"
        case .antigravity: return "atom"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .opencode: return "cube.transparent.fill"
        case .mimo: return "bolt.horizontal.circle.fill"
        case .openrouter: return "point.3.connected.trianglepath.dotted"
        case .deepseek: return "waveform.path.ecg"
        case .zai: return "cpu.fill"
        case .kimi: return "moon.stars.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .codex: return Color(red: 0.16, green: 0.78, blue: 0.58)
        case .claude: return Color(red: 0.88, green: 0.52, blue: 0.36)
        case .antigravity: return Color(red: 0.52, green: 0.80, blue: 0.09)
        case .copilot: return Color(red: 0.36, green: 0.62, blue: 0.98)
        case .cursor: return Color(red: 0.58, green: 0.52, blue: 0.98)
        case .opencode: return Color(red: 0.25, green: 0.82, blue: 0.88)
        case .mimo: return Color(red: 1.00, green: 0.45, blue: 0.16)
        case .openrouter: return Color(red: 0.46, green: 0.56, blue: 0.96)
        case .deepseek: return Color(red: 0.30, green: 0.55, blue: 0.98)
        case .zai: return Color(red: 0.24, green: 0.72, blue: 0.94)
        case .kimi: return Color(red: 0.68, green: 0.48, blue: 0.96)
        }
    }

    var dashboardURL: URL? {
        switch self {
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .claude: return URL(string: "https://claude.ai/settings/usage")
        case .antigravity: return URL(string: "https://one.google.com/ai")
        case .copilot: return URL(string: "https://github.com/settings/copilot")
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=usage")
        case .opencode: return URL(string: "https://opencode.ai/console")
        case .mimo: return URL(string: "https://platform.xiaomimimo.com/#/console/balance")
        case .openrouter: return URL(string: "https://openrouter.ai/activity")
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")
        case .zai: return URL(string: "https://bigmodel.cn/coding-plan/personal/usage")
        case .kimi: return URL(string: "https://www.kimi.com/code/console")
        }
    }

    var credentialHint: String {
        switch self {
        case .codex:
            return "Auto-reads ~/.codex/auth.json or ~/.local/share/opencode/auth.json (openai), or enter an OAuth token."
        case .claude:
            return "Auto-reads ~/.claude/.credentials.json, ~/.local/share/opencode/auth.json (anthropic), or enter an OAuth token / Admin key (sk-ant-admin...)."
        case .antigravity:
            return "Auto-probes `agy --print /usage` CLI & local conversation DBs (~/.gemini/antigravity), or enter a Google Cloud Code OAuth access token."
        case .copilot:
            return "Auto-reads ~/.config/github-copilot/apps.json, ~/.local/share/opencode/auth.json, or sign in via GitHub Device Flow."
        case .cursor:
            return "Auto-reads Cursor.app local database (state.vscdb) / ~/.config/cursor/auth.json, or enter a cursor.com Cookie header."
        case .opencode:
            return "Auto-reads ~/.local/share/opencode/opencode.db local cost history and auth.json, or enter an OpenCode Go API key."
        case .mimo:
            return "Uses official GET https://api.xiaomimimo.com/v1/platform/balance (sk-...) or Token Plan API (tp-...). Auto-reads OpenCode credentials or MIMO_API_KEY."
        case .openrouter:
            return "Enter an OpenRouter API key (sk-or-v1-...) or set OPENROUTER_API_KEY."
        case .deepseek:
            return "Uses official GET https://api.deepseek.com/user/balance. Auto-reads OpenCode credentials or enter a DeepSeek API key / DEEPSEEK_API_KEY."
        case .zai:
            return "Enter a GLM / z.ai API key or auto-read ~/.config/bigmodel/api_key, Z_AI_API_KEY, or GLM_API_KEY."
        case .kimi:
            return "Auto-reads ~/.kimi-code/credentials/kimi-code.json or enter a Kimi Code / Moonshot API key."
        }
    }

    var supportsRegionSelection: Bool {
        switch self {
        case .mimo, .zai, .kimi:
            return true
        default:
            return false
        }
    }

    var availableRegions: [(id: String, title: String)] {
        switch self {
        case .mimo:
            return [
                ("cn", "China Mainland (api.xiaomimimo.com / token-plan-cn)"),
                ("sgp", "Singapore (token-plan-sgp)"),
                ("ams", "Europe (token-plan-ams)")
            ]
        case .zai:
            return [
                ("cn", "BigModel China (open.bigmodel.cn)"),
                ("global", "z.ai Global (api.z.ai)")
            ]
        case .kimi:
            return [
                ("cn", "China Mainland (api.kimi.com / api.moonshot.cn)"),
                ("global", "International (api.kimi.ai / api.moonshot.ai)")
            ]
        default:
            return []
        }
    }

    var defaultRegion: String {
        switch self {
        case .mimo, .zai, .kimi:
            return "cn"
        default:
            return "default"
        }
    }

    /// Outer ring color (5h / primary window): provider accent color, shifting to orange/red at 80%/95%.
    func outerRingColor(for window: AIUsageRateWindow) -> Color {
        if window.clampedUsedPercent >= 95 {
            return .red
        } else if window.clampedUsedPercent >= 80 {
            return .orange
        } else {
            return accentColor
        }
    }

    /// Inner ring color (weekly window): complementary cool tint distinct from outer ring, shifting to orange/red at 80%/95%.
    func innerRingColor(for window: AIUsageRateWindow) -> Color {
        if window.clampedUsedPercent >= 95 {
            return .red
        } else if window.clampedUsedPercent >= 80 {
            return .orange
        } else {
            switch self {
            case .copilot, .deepseek, .zai, .openrouter, .opencode:
                return Color(red: 0.72, green: 0.56, blue: 1.0)
            default:
                return Color(red: 0.36, green: 0.78, blue: 1.0)
            }
        }
    }
}

/// Renders the bundled CodexBar-aligned monochrome SVG brand icon for an AI provider,
/// falling back to the provider's SF Symbol if the asset is unavailable.
struct AIProviderIconView: View {
    let provider: AIProviderID
    let size: CGFloat

    var body: some View {
        Group {
            if NSImage(named: NSImage.Name(provider.iconAssetName)) != nil {
                Image(provider.iconAssetName)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: provider.symbolName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Pool Ring Grouping & Shared Ring Gauges

/// Groups a model pool's 5h (outer ring) and weekly (inner ring) windows together.
struct AIUsageRingGroup: Identifiable {
    let id: String
    let label: String
    let outerWindow: AIUsageRateWindow        // 5h (or primary when single ring)
    let innerWindow: AIUsageRateWindow?       // weekly (nil for single ring)

    var isDual: Bool { innerWindow != nil }

    private enum WindowSlot {
        case fiveHour
        case weekly
        case other
    }

    static func build(from windows: [AIUsageRateWindow]) -> [AIUsageRingGroup] {
        var order: [String] = []
        var poolLabels: [String: String] = [:]
        var fiveHourByPool: [String: AIUsageRateWindow] = [:]
        var weeklyByPool: [String: AIUsageRateWindow] = [:]
        var standaloneByKey: [String: AIUsageRateWindow] = [:]

        for window in windows {
            let (poolKey, poolLabel, slot) = classifyWindow(window)
            switch slot {
            case .fiveHour:
                if !order.contains(poolKey) { order.append(poolKey) }
                if poolLabels[poolKey] == nil { poolLabels[poolKey] = poolLabel }
                if fiveHourByPool[poolKey] == nil {
                    fiveHourByPool[poolKey] = window
                } else {
                    let uniqueKey = "extra_\(window.id)"
                    order.append(uniqueKey)
                    poolLabels[uniqueKey] = shortSingleLabel(for: window)
                    standaloneByKey[uniqueKey] = window
                }
            case .weekly:
                if !order.contains(poolKey) { order.append(poolKey) }
                if poolLabels[poolKey] == nil { poolLabels[poolKey] = poolLabel }
                if weeklyByPool[poolKey] == nil {
                    weeklyByPool[poolKey] = window
                } else {
                    let uniqueKey = "extra_\(window.id)"
                    order.append(uniqueKey)
                    poolLabels[uniqueKey] = shortSingleLabel(for: window)
                    standaloneByKey[uniqueKey] = window
                }
            case .other:
                let uniqueKey = "single_\(window.id)"
                order.append(uniqueKey)
                poolLabels[uniqueKey] = poolLabel
                standaloneByKey[uniqueKey] = window
            }
        }

        var result: [AIUsageRingGroup] = []
        for key in order {
            if let standalone = standaloneByKey[key] {
                result.append(
                    AIUsageRingGroup(
                        id: key,
                        label: poolLabels[key] ?? shortSingleLabel(for: standalone),
                        outerWindow: standalone,
                        innerWindow: nil
                    )
                )
            } else if let w5h = fiveHourByPool[key], let w7d = weeklyByPool[key] {
                result.append(
                    AIUsageRingGroup(
                        id: "dual_\(key)",
                        label: poolLabels[key] ?? "5h/7d",
                        outerWindow: w5h,
                        innerWindow: w7d
                    )
                )
            } else if let w5h = fiveHourByPool[key] {
                result.append(
                    AIUsageRingGroup(
                        id: "5h_\(key)",
                        label: shortSingleLabel(for: w5h),
                        outerWindow: w5h,
                        innerWindow: nil
                    )
                )
            } else if let w7d = weeklyByPool[key] {
                result.append(
                    AIUsageRingGroup(
                        id: "7d_\(key)",
                        label: shortSingleLabel(for: w7d),
                        outerWindow: w7d,
                        innerWindow: nil
                    )
                )
            }
        }
        return result
    }

    private static func classifyWindow(_ window: AIUsageRateWindow) -> (poolKey: String, poolLabel: String, slot: WindowSlot) {
        let label = window.label
        let lower = label.lowercased()

        // Named model pools with explicit " 5h" or " Weekly" suffix (e.g. Antigravity)
        if label.hasSuffix(" 5h") {
            let base = String(label.dropLast(3)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty {
                return (base.lowercased(), shortenPoolName(base), .fiveHour)
            }
        }
        if label.hasSuffix(" Weekly") {
            let base = String(label.dropLast(7)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty {
                return (base.lowercased(), shortenPoolName(base), .weekly)
            }
        }

        // Claude model-specific weekly buckets stay separate from the main 5h + Weekly All Models pair
        if window.id == "claude_seven_day_sonnet" {
            return ("sonnet", "Sonnet", .other)
        }
        if window.id == "claude_seven_day_opus" {
            return ("opus", "Opus", .other)
        }
        if window.id == "claude_seven_day_oauth_apps" {
            return ("oauth", "OAuth", .other)
        }

        // Shared default provider pool: 5h + Weekly (Codex, Claude All, OpenCode, GLM / z.ai)
        if window.id == "codex_5h"
            || window.id == "claude_five_hour"
            || window.id == "opencode_5h"
            || window.id == "opencode_local_5h"
            || lower.contains("5-hour")
            || lower.hasPrefix("5h ")
            || lower == "5h"
        {
            return ("default", "All", .fiveHour)
        }

        if window.id == "codex_weekly"
            || window.id == "claude_seven_day"
            || window.id == "opencode_weekly"
            || window.id == "opencode_local_7d"
            || lower == "weekly limit"
            || lower == "weekly all models"
            || lower == "weekly quota"
            || lower.hasPrefix("7d ")
        {
            return ("default", "All", .weekly)
        }

        return (window.id, shortSingleLabel(for: window), .other)
    }

    private static func shortenPoolName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "claude/gpt" { return "Claude/GPT" }
        if lower == "gemini argon" { return "Argon" }
        return name
    }

    static func shortSingleLabel(for window: AIUsageRateWindow) -> String {
        let raw = window.label
        switch raw {
        case "5-Hour Session", "5-Hour Rolling", "5-Hour Quota", "5h Spend":
            return "5h"
        case "Weekly Limit", "Weekly All Models", "Weekly Quota", "7d Spend":
            return "7d"
        case "Monthly Limit":
            return "30d"
        case "Weekly Sonnet":
            return "Sonnet"
        case "Weekly Opus":
            return "Opus"
        case "Gemini Argon Weekly":
            return "Argon"
        case "Premium Requests":
            return "Prem"
        case "Chat Quota":
            return "Chat"
        case "Plan Included", "Token Plan Quota":
            return "Plan"
        case "Key Cap":
            return "Cap"
        case "MCP Quota":
            return "MCP"
        default:
            return raw
                .replacingOccurrences(of: " Weekly", with: "")
                .replacingOccurrences(of: " Quota", with: "")
                .replacingOccurrences(of: " Limit", with: "")
        }
    }
}

struct AIUsageDualRingGauge: View {
    @Environment(\.notchGlassInk) private var ink
    let outerProgress: Double
    let innerProgress: Double
    let outerColor: Color
    let innerColor: Color
    let size: CGFloat
    let outerLineWidth: CGFloat
    let innerLineWidth: CGFloat
    let ringGap: CGFloat
    var outerTrackColor: Color? = nil
    var innerTrackColor: Color? = nil

    var body: some View {
        let clampedOuter = normalizedTrim(outerProgress)
        let clampedInner = normalizedTrim(innerProgress)
        let innerSize = max(8, size - (outerLineWidth + ringGap) * 2)
        let resolvedOuterTrack = outerTrackColor ?? ink.track(0.13)
        let resolvedInnerTrack = innerTrackColor ?? ink.track(0.11)

        ZStack {
            // Outer ring track (5h)
            Circle()
                .stroke(resolvedOuterTrack, lineWidth: outerLineWidth)
                .frame(width: size, height: size)

            // Outer ring fill (5h)
            Circle()
                .trim(from: 0, to: clampedOuter)
                .stroke(
                    outerColor,
                    style: StrokeStyle(lineWidth: outerLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)

            // Inner ring track (Weekly)
            Circle()
                .stroke(resolvedInnerTrack, lineWidth: innerLineWidth)
                .frame(width: innerSize, height: innerSize)

            // Inner ring fill (Weekly)
            Circle()
                .trim(from: 0, to: clampedInner)
                .stroke(
                    innerColor,
                    style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: innerSize, height: innerSize)
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.25), value: outerProgress)
        .animation(.smooth(duration: 0.25), value: innerProgress)
    }

    private func normalizedTrim(_ value: Double) -> CGFloat {
        let clamped = min(1.0, max(0.0, value))
        if clamped > 0 && clamped < 0.03 { return 0.03 }
        return CGFloat(clamped)
    }
}

struct AIUsageSingleRingGauge: View {
    @Environment(\.notchGlassInk) private var ink
    let progress: Double
    let color: Color
    let centerLabel: String?
    let size: CGFloat
    let lineWidth: CGFloat
    var trackColor: Color? = nil
    var labelColor: Color? = nil

    var body: some View {
        let clamped: CGFloat = {
            let v = min(1.0, max(0.0, progress))
            if v > 0 && v < 0.03 { return 0.03 }
            return CGFloat(v)
        }()
        let resolvedTrack = trackColor ?? ink.track(0.13)
        let resolvedLabel = labelColor ?? ink.primary(0.92)

        ZStack {
            Circle()
                .stroke(resolvedTrack, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            if let centerLabel {
                Text(centerLabel)
                    .font(.system(size: size >= 32 ? 8.5 : 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(resolvedLabel)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.25), value: progress)
    }
}

// MARK: - Provider Configuration

enum AIAuthSourceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case localOAuth = "oauth"
    case apiKey = "api"
    case cookie = "cookie"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .localOAuth: return "Local CLI / OAuth"
        case .apiKey: return "API Key / Token"
        case .cookie: return "Cookie Header"
        }
    }
}

struct AIProviderConfig: Codable, Equatable, Sendable {
    var provider: AIProviderID
    var sourceMode: AIAuthSourceMode = .auto
    var region: String
    var customBaseURL: String = ""

    init(provider: AIProviderID) {
        self.provider = provider
        self.region = provider.defaultRegion
    }
}

// MARK: - Normalized Usage Snapshot

struct AIUsageRateWindow: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var label: String
    var usedPercent: Double
    var detailText: String?
    var resetAt: Date?
    var isEstimated: Bool = false

    var clampedUsedPercent: Double {
        min(100, max(0, usedPercent))
    }

    var remainingPercent: Double {
        max(0, 100 - clampedUsedPercent)
    }

    /// Severity level following OpenCode's 80% / 90% / 95% rate-limit warning thresholds.
    var severityColor: Color {
        if clampedUsedPercent >= 95 {
            return .red
        } else if clampedUsedPercent >= 80 {
            return .orange
        } else {
            return .accentColor
        }
    }

    var resetCountdownText: String? {
        guard let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSinceNow
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

    var compactResetCountdownText: String? {
        guard let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSinceNow
        guard remaining > 0 else { return "Now" }
        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }
}

struct AIUsageCurrencyBalance: Identifiable, Codable, Equatable, Sendable {
    var currency: String
    var remaining: Double
    var granted: Double?
    var toppedUp: Double?

    var id: String { currency }

    var formattedRemaining: String {
        AIUsageBalance.formatAmount(remaining, currency: currency)
    }

    /// Concise formatted amount for the closed-notch right wing (e.g. "¥12.34", "$5.20", "720").
    var compactClosedNotchAmount: String {
        let upper = currency.uppercased()
        if upper == "CREDITS" || upper == "PTS" || upper == "TOKENS" || upper == "TOK" {
            if remaining >= 1_000_000_000 { return String(format: "%.1fB", remaining / 1_000_000_000) }
            if remaining >= 1_000_000 { return String(format: "%.1fM", remaining / 1_000_000) }
            if remaining >= 1_000 { return String(format: "%.1fK", remaining / 1_000) }
            return String(format: "%.0f", remaining)
        }
        let symbol: String
        switch upper {
        case "CNY", "RMB": symbol = "¥"
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        default: symbol = ""
        }
        if abs(remaining) >= 1_000 {
            return String(format: "%@%.0f", symbol, remaining)
        }
        return String(format: "%@%.2f", symbol, remaining)
    }
}

struct AIUsageBalance: Codable, Equatable, Sendable {
    var currency: String
    var remaining: Double?
    var granted: Double?
    var toppedUp: Double?
    var usedThisPeriod: Double?
    var limit: Double?
    var periodLabel: String?
    var additionalBalances: [AIUsageCurrencyBalance]? = nil

    var allCurrencyBalances: [AIUsageCurrencyBalance] {
        var list: [AIUsageCurrencyBalance] = []
        if let remaining {
            list.append(
                AIUsageCurrencyBalance(
                    currency: currency,
                    remaining: remaining,
                    granted: granted,
                    toppedUp: toppedUp
                )
            )
        }
        if let additionalBalances {
            list.append(contentsOf: additionalBalances)
        }
        if list.count > 1 {
            let nonZero = list.filter { $0.remaining >= 0.005 }
            if !nonZero.isEmpty {
                return nonZero
            }
            return Array(list.prefix(1))
        }
        return list
    }

    var formattedRemaining: String {
        let all = allCurrencyBalances
        guard !all.isEmpty else { return "—" }
        return all.map(\.formattedRemaining).joined(separator: " · ")
    }

    /// Shorter formatting for compact Notch card header badges (e.g. "720 cr")
    var compactFormattedRemaining: String {
        let all = allCurrencyBalances
        guard !all.isEmpty else { return "—" }
        return all.map { item in
            let upper = item.currency.uppercased()
            if upper == "CREDITS" || upper == "PTS" {
                let v = item.remaining
                if v >= 1_000_000_000 { return String(format: "%.1fB cr", v / 1_000_000_000) }
                if v >= 1_000_000 { return String(format: "%.1fM cr", v / 1_000_000) }
                if v >= 1_000 { return String(format: "%.1fK cr", v / 1_000) }
                return String(format: "%.0f cr", v)
            }
            return item.formattedRemaining
        }.joined(separator: " · ")
    }

    var formattedBreakdown: String? {
        var parts: [String] = []
        let all = allCurrencyBalances
        if all.count > 1 {
            for item in all {
                if let toppedUp = item.toppedUp, let granted = item.granted, granted > 0 {
                    parts.append("Paid \(Self.formatAmount(toppedUp, currency: item.currency))")
                    parts.append("Gift \(Self.formatAmount(granted, currency: item.currency))")
                }
            }
        } else if let toppedUp, let granted, granted > 0 {
            parts.append("Paid \(Self.formatAmount(toppedUp, currency: currency))")
            parts.append("Gift \(Self.formatAmount(granted, currency: currency))")
        }
        if let usedThisPeriod {
            let label = periodLabel ?? "Used"
            if let limit, limit > 0 {
                parts.append("\(label): \(Self.formatAmount(usedThisPeriod, currency: currency)) / \(Self.formatAmount(limit, currency: currency))")
            } else {
                parts.append("\(label): \(Self.formatAmount(usedThisPeriod, currency: currency))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func formatAmount(_ value: Double, currency: String) -> String {
        let upper = currency.uppercased()
        let symbol: String
        switch upper {
        case "CNY", "RMB": symbol = "¥"
        case "USD": symbol = "$"
        case "EUR": symbol = "€"
        case "CREDITS", "PTS":
            if value >= 1_000_000_000 {
                return String(format: "%.2fB credits", value / 1_000_000_000)
            } else if value >= 1_000_000 {
                return String(format: "%.2fM credits", value / 1_000_000)
            } else if value >= 1_000 {
                return String(format: "%.1fK credits", value / 1_000)
            }
            return String(format: "%.0f credits", value)
        case "TOKENS", "TOK":
            if value >= 1_000_000_000 {
                return String(format: "%.2fB tok", value / 1_000_000_000)
            } else if value >= 1_000_000 {
                return String(format: "%.1fM tok", value / 1_000_000)
            } else if value >= 1_000 {
                return String(format: "%.1fK tok", value / 1_000)
            }
            return String(format: "%.0f tok", value)
        default:
            symbol = "\(upper) "
        }
        return String(format: "%@%.2f", symbol, value)
    }
}

struct AIProviderSnapshot: Identifiable, Codable, Equatable, Sendable {
    var provider: AIProviderID
    var sourceLabel: String
    var accountLabel: String?
    var planName: String?
    var windows: [AIUsageRateWindow]
    var balance: AIUsageBalance?
    var statusNote: String?
    var errorMessage: String?
    var updatedAt: Date

    var id: String { provider.rawValue }

    var isConnected: Bool {
        errorMessage == nil && (!windows.isEmpty || balance != nil)
    }

    var primaryWindow: AIUsageRateWindow? {
        windows.first
    }

    var secondaryWindow: AIUsageRateWindow? {
        windows.dropFirst().first
    }
}

// MARK: - Local Secret Store for User-Configured Credentials

/// Stores user-provided API keys and Cookie headers in powerNotch's sandboxed
/// `Application Support/powerNotch/ai-usage-secrets.json` (POSIX 0600) so ad-hoc signed
/// builds never trigger macOS login Keychain ACL prompts on settings open or rebuilds.
enum AIUsageKeychainStore {
    private static let store: DualTrackSecretStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = support.appendingPathComponent("powerNotch", isDirectory: true)
            .appendingPathComponent("ai-usage-secrets.json")
        return DualTrackSecretStore(fileStore: POSIXAtomicSecretFileStore(fileURL: url))
    }()

    static func readSecret(for provider: AIProviderID, kind: String = "secret") -> String? {
        let key = "\(provider.rawValue).\(kind)"
        guard let raw = store.read(account: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func writeSecret(_ value: String, for provider: AIProviderID, kind: String = "secret") {
        let key = "\(provider.rawValue).\(kind)"
        store.write(value, account: key)
    }

    /// Reads an external Keychain item (such as `Claude Code-credentials`) ONLY when the user
    /// explicitly enables external Keychain reads and triggers a refresh.
    static func readExternalGenericPassword(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
