import AppKit
import Defaults

/// Dark glass with material intensity scoped to this app, independent of system preferences.
@MainActor
enum LiquidGlassAppearance {
    static let tintOpacity: Double = 0.5

    private static let materialPreferenceKey = "NSGlassTintAmount"
    private static let diffusionDidChange = Notification.Name("NSGlassEffectDiffusionDidChangeNotification")
    private static var updatesTask: Task<Void, Never>?

    // Match the system slider's continuous, normalized Float range.
    static func materialAmount(for value: Double) -> Float {
        guard value.isFinite else { return 1 }
        return Float(min(1, max(0, value)))
    }

    static func configure() {
        guard updatesTask == nil else { return }
        apply(Defaults[.liquidGlassOpacity])
        updatesTask = Task {
            for await value in Defaults.updates(.liquidGlassOpacity) {
                guard !Task.isCancelled else { break }
                apply(value)
            }
        }
    }

    static func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    private static func apply(_ value: Double) {
        UserDefaults.standard.set(materialAmount(for: value), forKey: materialPreferenceKey)
        // Refresh AppKit's cached material in this process only.
        NotificationCenter.default.post(name: diffusionDidChange, object: nil)
    }
}
