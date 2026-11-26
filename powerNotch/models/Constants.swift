//
//  Constants.swift
//  powerNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import AppKit
import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
    static let displayNotchVisibilityChanged = Notification.Name("displayNotchVisibilityChanged")
}

/// Per-display Dynamic Island layout overrides configured in Developer Options.
struct DisplayDynamicIslandTuning: Codable, Equatable, Defaults.Serializable {
    /// Vertical offset in points relative to the display's default Dynamic Island position.
    /// Positive moves the island downward; negative moves it upward.
    var verticalOffset: Double = 0
    /// Optional explicit total closed Dynamic Island height in points.
    /// When `nil`, the display's automatic default height is used.
    var totalHeight: Double? = nil

    var isDefault: Bool {
        verticalOffset == 0 && totalHeight == nil
    }
}

@MainActor
enum DisplayNotchSettings {
    static let verticalOffsetRange: ClosedRange<Double> = -12...24
    static let totalHeightRange: ClosedRange<Double> = 14...48
    /// Default height trim (pt) below the system menu bar height (`H_mb - 1pt`)
    /// applied uniformly across both notched and non-notched displays.
    static let menuBarDefaultHeightTrim: CGFloat = 1.0

    /// Returns whether the notch should be shown on the given display.
    static func isEnabled(for screen: NSScreen) -> Bool {
        guard let uuid = screen.displayUUID else { return false }
        return isEnabled(forUUID: uuid)
    }

    static func isEnabled(
        forUUID uuid: String,
        overrides: [String: Bool] = Defaults[.displayNotchVisibility]
    ) -> Bool {
        // Every display is enabled out of the box; an explicit Off choice wins.
        overrides[uuid] ?? true
    }

    /// Returns all currently connected displays that have the notch enabled.
    static func enabledScreens(
        connectedScreens: [NSScreen] = NSScreen.screens
    ) -> [NSScreen] {
        connectedScreens.filter { screen in
            guard let uuid = screen.displayUUID else { return false }
            return isEnabled(forUUID: uuid)
        }
    }

    /// Sets notch visibility for a single display while preserving the current effective
    /// visibility of all other connected displays.
    static func setEnabled(
        _ enabled: Bool,
        forUUID targetUUID: String,
        connectedScreens: [NSScreen] = NSScreen.screens
    ) {
        var updated = Defaults[.displayNotchVisibility]
        for screen in connectedScreens {
            guard let uuid = screen.displayUUID else { continue }
            if updated[uuid] == nil {
                updated[uuid] = isEnabled(forUUID: uuid)
            }
        }
        updated[targetUUID] = enabled
        Defaults[.displayNotchVisibility] = updated
        NotificationCenter.default.post(name: .displayNotchVisibilityChanged, object: nil)
    }

    /// Explicit per-display and global choices win; otherwise use the display's hardware.
    static func usesDynamicIsland(
        forUUID uuid: String?,
        overrides: [String: Bool] = Defaults[.displayDynamicIslandShape],
        defaultEnabled: Bool? = Defaults[.dynamicIslandShape]
    ) -> Bool {
        let screen = uuid.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        return resolvedDynamicIslandMode(
            hasPhysicalNotch: (screen?.safeAreaInsets.top ?? 0) > 0,
            override: uuid.flatMap { overrides[$0] },
            defaultEnabled: defaultEnabled
        )
    }

    static func resolvedDynamicIslandMode(
        hasPhysicalNotch: Bool,
        override: Bool?,
        defaultEnabled: Bool?
    ) -> Bool {
        override ?? defaultEnabled ?? !hasPhysicalNotch
    }

    /// Sets Dynamic Island vs. Hanging Notch shape for a single display while preserving the
    /// current effective mode of all other connected displays.
    static func setUsesDynamicIsland(
        _ enabled: Bool,
        forUUID targetUUID: String,
        connectedScreens: [NSScreen] = NSScreen.screens
    ) {
        var updated = Defaults[.displayDynamicIslandShape]
        let fallback = Defaults[.dynamicIslandShape]
        for screen in connectedScreens {
            guard let uuid = screen.displayUUID else { continue }
            if updated[uuid] == nil {
                updated[uuid] = usesDynamicIsland(forUUID: uuid, overrides: updated, defaultEnabled: fallback)
            }
        }
        updated[targetUUID] = enabled
        Defaults[.displayDynamicIslandShape] = updated
    }

    /// One-click action enabling all connected displays in Dynamic Island (`true`) or Hanging
    /// Notch (`false`) mode, and updating the global default for newly connected displays.
    static func setUsesDynamicIslandForAllDisplays(
        _ enabled: Bool,
        connectedScreens: [NSScreen] = NSScreen.screens
    ) {
        Defaults[.displayDynamicIslandShape] = [:]
        Defaults[.dynamicIslandShape] = enabled
        setAllDisplaysEnabled(true, connectedScreens: connectedScreens)
    }

    /// One-click action enabling or disabling the notch across all connected displays.
    static func setAllDisplaysEnabled(
        _ enabled: Bool,
        connectedScreens: [NSScreen] = NSScreen.screens
    ) {
        var updated = Defaults[.displayNotchVisibility]
        for screen in connectedScreens {
            guard let uuid = screen.displayUUID else { continue }
            updated[uuid] = enabled
        }
        Defaults[.displayNotchVisibility] = updated
        NotificationCenter.default.post(name: .displayNotchVisibilityChanged, object: nil)
    }

    /// Default top clearance (pt) below the screen's top edge for Dynamic Island on the given screen.
    static func defaultDynamicIslandTopInset(for screen: NSScreen) -> CGFloat {
        0
    }

    /// Returns the display's system menu bar height (`frame.maxY - visibleFrame.maxY`),
    /// falling back to `safeAreaInsets.top` or closed notch height if the menu bar is globally auto-hidden.
    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let visibleMenuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if visibleMenuBar > 0 {
            return visibleMenuBar
        }
        if screen.safeAreaInsets.top > 0 {
            return screen.safeAreaInsets.top
        }
        return getClosedNotchSize(screenUUID: screen.displayUUID).height
    }

    /// Default closed notch / Dynamic Island total height (pt) on the given screen when no developer override is set.
    static func defaultDynamicIslandHeight(for screen: NSScreen) -> CGFloat {
        let hmb = menuBarHeight(for: screen)
        guard hmb > 0 else { return 0 }
        return max(14, hmb - menuBarDefaultHeightTrim)
    }

    static func tuning(forUUID uuid: String?) -> DisplayDynamicIslandTuning {
        guard let uuid else { return DisplayDynamicIslandTuning() }
        return Defaults[.displayDynamicIslandTuning][uuid] ?? DisplayDynamicIslandTuning()
    }

    static func setTuning(_ tuning: DisplayDynamicIslandTuning, forUUID uuid: String) {
        var all = Defaults[.displayDynamicIslandTuning]
        if tuning.isDefault {
            all.removeValue(forKey: uuid)
        } else {
            all[uuid] = tuning
        }
        Defaults[.displayDynamicIslandTuning] = all
    }

    static func resetTuning(forUUID uuid: String) {
        var all = Defaults[.displayDynamicIslandTuning]
        all.removeValue(forKey: uuid)
        Defaults[.displayDynamicIslandTuning] = all
    }

    static func resetAllTuning() {
        Defaults[.displayDynamicIslandTuning] = [:]
    }
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"
    case neteaseMusic = "NetEase Cloud Music"
    
    var id: String { self.rawValue }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

enum HapticFeedbackLevel: Int, CaseIterable, Identifiable, Defaults.Serializable {
    case off = 0
    case light = 1
    case medium = 2
    case strong = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    var feedbackPattern: NSHapticFeedbackManager.FeedbackPattern? {
        switch self {
        case .off: return nil
        case .light: return .levelChange
        case .medium: return .alignment
        case .strong: return .generic
        }
    }

    func perform() {
        guard let pattern = feedbackPattern else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    static func performConfigured() {
        Defaults[.hapticFeedbackLevel].perform()
    }
}

enum LiquidGlassAppearanceMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case followSystem = "followSystem"
    case light = "light"
    case dark = "dark"
    case custom = "custom"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .followSystem: return "Follow system"
        case .light: return "Light"
        case .dark: return "Dark"
        case .custom: return "Custom"
        }
    }
}

enum MediaColorStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case systemDefault = "default"
    case albumArt = "albumArt"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: return "Default"
        case .albumArt: return "Match album art"
        case .custom: return "Custom"
        }
    }

    static func resolvedCustomNSColor(from data: Data? = Defaults[.customMediaColorData]) -> NSColor {
        if let data,
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        {
            return nsColor
        }
        return NSColor.effectiveAccent
    }

    static func archiveCustomColor(_ color: Color) -> Data? {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: true)
    }
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let displayNotchVisibility = Key<[String: Bool]>("displayNotchVisibility", default: [:])
    static let releaseName = Key<String>("releaseName", default: "Thunder⚡️")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let hapticFeedbackLevel = Key<HapticFeedbackLevel>(
        "hapticFeedbackLevel",
        default: (UserDefaults.standard.object(forKey: "enableHaptics") as? Bool) == false ? .off : .medium
    )
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Developer
    static let developerOptionsEnabled = Key<Bool>("developerOptionsEnabled", default: false)
    static let developerAnimationSpeed = Key<Double>("developerAnimationSpeed", default: 1.0)
    static let developerClearLiquidGlass = Key<Bool>("developerClearLiquidGlass", default: false)
    static let displayDynamicIslandTuning = Key<[String: DisplayDynamicIslandTuning]>(
        "displayDynamicIslandTuning",
        default: [:]
    )

    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)
    static let liquidGlassNotch = Key<Bool>("liquidGlassNotch", default: true)
    static let liquidGlassAppearanceMode = Key<LiquidGlassAppearanceMode>(
        "liquidGlassAppearanceMode",
        default: {
            if let legacyStyle = UserDefaults.standard.string(forKey: "liquidGlassStyle"),
               let migrated = LiquidGlassAppearanceMode(rawValue: legacyStyle)
            {
                return migrated
            }
            if (UserDefaults.standard.object(forKey: "developerClearLiquidGlass") as? Bool) == true {
                return .light
            }
            return .followSystem
        }()
    )
    static let liquidGlassOpacity = Key<Double>("liquidGlassOpacity", default: 0.95)
    static let customGlassColorData = Key<Data?>("customGlassColorData", default: nil)
    // nil means automatic per-display mode. Persisted Bool values from earlier versions
    // and the explicit "all displays" actions retain their existing meaning.
    static let dynamicIslandShape = Key<Bool?>("dynamicIslandShape", default: nil)
    static let displayDynamicIslandShape = Key<[String: Bool]>("displayDynamicIslandShape", default: [:])

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let mediaColorStyle = Key<MediaColorStyle>(
        "mediaColorStyle",
        default: {
            if let sliderRaw = UserDefaults.standard.string(forKey: "sliderUseAlbumArtColor"),
               sliderRaw == SliderColorEnum.albumArt.rawValue
            {
                return .albumArt
            }
            if (UserDefaults.standard.object(forKey: "coloredSpectrogram") as? Bool) == false {
                return .systemDefault
            }
            return .albumArt
        }()
    )
    static let customMediaColorData = Key<Data?>("customMediaColorData", default: nil)
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [])
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: true)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: false)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: false)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: false)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: false)
    
    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    
    // MARK: Shelf
    static let boringShelf = Key<Bool>("boringShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    
    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    @MainActor static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    @MainActor static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)

    // MARK: AI Usage Monitor
    static let enableAIUsageNotchTab = Key<Bool>("enableAIUsageNotchTab", default: false)
    static let aiUsageRefreshInterval = Key<Int>("aiUsageRefreshInterval", default: 300)
    static let aiUsageShowRemainingPercent = Key<Bool>("aiUsageShowRemainingPercent", default: false)
    static let aiUsageHideAccountEmails = Key<Bool>("aiUsageHideAccountEmails", default: false)
    static let aiUsageAllowExternalKeychain = Key<Bool>("aiUsageAllowExternalKeychain", default: false)
    static let aiUsageEnabledProviders = Key<[String]>(
        "aiUsageEnabledProviders",
        default: ["codex", "claude", "antigravity", "copilot", "cursor", "opencode", "mimo"]
    )
    static let aiUsagePinnedRingID = Key<String>("aiUsagePinnedRingID", default: "")
    static let aiUsageProviderConfigsData = Key<Data?>("aiUsageProviderConfigsData", default: nil)
    static let aiUsageCachedSnapshotsData = Key<Data?>("aiUsageCachedSnapshotsData", default: nil)
    static let aiUsageCurrencyRatesData = Key<Data?>("aiUsageCurrencyRatesData", default: nil)
}
