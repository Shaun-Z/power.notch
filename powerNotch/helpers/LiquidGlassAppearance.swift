import AppKit
import Combine
import Defaults
import SwiftUI

/// Adaptive foreground/surface ink palette for the notch silhouette.
/// Dark glass (default) keeps white-based inks unchanged; colorless clear glass
/// automatically switches light inks to high-contrast dark inks for legibility.
struct NotchGlassInk: Equatable, Sendable {
    static let dark = NotchGlassInk(isClearGlass: false)
    static let clear = NotchGlassInk(isClearGlass: true)

    let isClearGlass: Bool

    var base: Color {
        isClearGlass ? .black : .white
    }

    func primary(_ darkOpacity: Double = 1.0) -> Color {
        if isClearGlass {
            let mapped = min(0.92, max(0.76, darkOpacity * 0.90))
            return Color.black.opacity(mapped)
        }
        return Color.white.opacity(darkOpacity)
    }

    func secondary(_ darkOpacity: Double = 0.65) -> Color {
        if isClearGlass {
            let mapped = min(0.74, max(0.56, darkOpacity * 0.96))
            return Color.black.opacity(mapped)
        }
        return Color.white.opacity(darkOpacity)
    }

    func tertiary(_ darkOpacity: Double = 0.45) -> Color {
        if isClearGlass {
            let mapped = min(0.58, max(0.42, darkOpacity * 1.04))
            return Color.black.opacity(mapped)
        }
        return Color.white.opacity(darkOpacity)
    }

    func surface(_ darkOpacity: Double) -> Color {
        if isClearGlass {
            return Color.black.opacity(min(0.22, max(0.05, darkOpacity * 0.85)))
        }
        return Color.white.opacity(darkOpacity)
    }

    func border(_ darkOpacity: Double) -> Color {
        if isClearGlass {
            return Color.black.opacity(min(0.30, max(0.08, darkOpacity * 0.85)))
        }
        return Color.white.opacity(darkOpacity)
    }

    func track(_ darkOpacity: Double = 0.16) -> Color {
        if isClearGlass {
            return Color.black.opacity(max(0.14, darkOpacity))
        }
        return Color.white.opacity(darkOpacity)
    }

    func accent(_ color: Color, clearMaxBrightness: CGFloat = 0.46) -> Color {
        isClearGlass ? color.ensureMaximumBrightness(factor: clearMaxBrightness) : color
    }

    func tinted(_ nsColor: NSColor, darkMinBrightness: CGFloat = 0.6, clearMaxBrightness: CGFloat = 0.42) -> Color {
        if isClearGlass {
            return Color(nsColor: nsColor).ensureMaximumBrightness(factor: clearMaxBrightness)
        }
        return Color(nsColor: nsColor).ensureMinimumBrightness(factor: darkMinBrightness)
    }
}

private struct NotchGlassInkKey: EnvironmentKey {
    static let defaultValue: NotchGlassInk = .dark
}

extension EnvironmentValues {
    var notchGlassInk: NotchGlassInk {
        get { self[NotchGlassInkKey.self] }
        set { self[NotchGlassInkKey.self] = newValue }
    }
}

/// Dark glass with material intensity scoped to this app, independent of system preferences.
@MainActor
enum LiquidGlassAppearance {
    static let tintOpacity: Double = 0.5

    static func customColor(from data: Data? = Defaults[.customGlassColorData]) -> NSColor {
        guard let data,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
              let rgb = color.usingColorSpace(.sRGB)
        else { return .systemBlue }
        return rgb.withAlphaComponent(1)
    }

    static func archiveCustomColor(_ color: Color) -> Data? {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemBlue
        return try? NSKeyedArchiver.archivedData(withRootObject: rgb.withAlphaComponent(1), requiringSecureCoding: true)
    }

    static func customColorUsesLightAppearance(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let brightness = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
        return brightness > 0.6
    }

    private static let materialPreferenceKey = "NSGlassTintAmount"
    private static let diffusionDidChange = Notification.Name("NSGlassEffectDiffusionDidChangeNotification")
    private static let systemThemeDidChange = Notification.Name("AppleInterfaceThemeChangedNotification")
    private static var updatesTask: Task<Void, Never>?
    private static var styleTask: Task<Void, Never>?
    private static var appearanceObservers: Set<AnyCancellable> = []

    // Match the system slider's continuous, normalized Float range.
    static func materialAmount(for value: Double) -> Float {
        guard value.isFinite else { return 1 }
        return Float(min(1, max(0, value)))
    }

    static var isSystemLightMode: Bool {
        if let app = NSApp {
            return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == nil
    }

    static func syncResolvedAppearance(
        isEnabled: Bool = Defaults[.liquidGlassNotch],
        mode: LiquidGlassAppearanceMode = Defaults[.liquidGlassAppearanceMode]
    ) {
        let usesLightGlass: Bool
        if !isEnabled {
            usesLightGlass = false
        } else {
            switch mode {
            case .dark:
                usesLightGlass = false
            case .light:
                usesLightGlass = true
            case .followSystem:
                usesLightGlass = isSystemLightMode
            case .custom:
                usesLightGlass = customColorUsesLightAppearance(customColor())
            }
        }

        if Defaults[.developerClearLiquidGlass] != usesLightGlass {
            Defaults[.developerClearLiquidGlass] = usesLightGlass
        }
    }

    static func configure() {
        if updatesTask == nil {
            apply(Defaults[.liquidGlassOpacity])
            updatesTask = Task {
                for await value in Defaults.updates(.liquidGlassOpacity) {
                    guard !Task.isCancelled else { break }
                    apply(value)
                }
            }
        }

        if styleTask == nil {
            syncResolvedAppearance()
            styleTask = Task {
                for await _ in Defaults.updates([.liquidGlassNotch, .liquidGlassAppearanceMode, .customGlassColorData]) {
                    guard !Task.isCancelled else { break }
                    syncResolvedAppearance()
                }
            }
        }

        if appearanceObservers.isEmpty {
            if let app = NSApp {
                app.publisher(for: \.effectiveAppearance)
                    .receive(on: RunLoop.main)
                    .sink { _ in
                        syncResolvedAppearance()
                    }
                    .store(in: &appearanceObservers)
            }

            DistributedNotificationCenter.default()
                .publisher(for: systemThemeDidChange)
                .receive(on: RunLoop.main)
                .sink { _ in
                    syncResolvedAppearance()
                }
                .store(in: &appearanceObservers)
        }
    }

    static func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        styleTask?.cancel()
        styleTask = nil
        appearanceObservers.removeAll()
    }

    private static func apply(_ value: Double) {
        UserDefaults.standard.set(materialAmount(for: value), forKey: materialPreferenceKey)
        // Refresh AppKit's cached material in this process only.
        NotificationCenter.default.post(name: diffusionDidChange, object: nil)
    }
}
