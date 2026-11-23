//
//  Constants.swift
//  powerNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

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
        return isEnabled(forUUID: uuid, connectedScreens: NSScreen.screens)
    }

    static func isEnabled(
        forUUID uuid: String,
        connectedScreens: [NSScreen] = NSScreen.screens
    ) -> Bool {
        let overrides = Defaults[.displayNotchVisibility]
        if let explicit = overrides[uuid] {
            return explicit
        }
        if overrides.isEmpty || Defaults[.automaticallySwitchDisplay] {
            if let mainUUID = NSScreen.main?.displayUUID {
                return uuid == mainUUID
            }
            return uuid == connectedScreens.first?.displayUUID
        }
        return false
    }

    /// Returns all currently connected displays that have the notch enabled.
    static func enabledScreens(
        connectedScreens: [NSScreen] = NSScreen.screens
    ) -> [NSScreen] {
        connectedScreens.filter { screen in
            guard let uuid = screen.displayUUID else { return false }
            return isEnabled(forUUID: uuid, connectedScreens: connectedScreens)
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
                updated[uuid] = isEnabled(
                    forUUID: uuid,
                    connectedScreens: connectedScreens
                )
            }
        }
        updated[targetUUID] = enabled
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

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let displayNotchVisibility = Key<[String: Bool]>("displayNotchVisibility", default: [:])
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
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
    static let liquidGlassOpacity = Key<Double>("liquidGlassOpacity", default: 1.0)
    static let dynamicIslandShape = Key<Bool>("dynamicIslandShape", default: false)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
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
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    
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
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)

    // MARK: AI Usage Monitor
    static let enableAIUsageNotchTab = Key<Bool>("enableAIUsageNotchTab", default: true)
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
}
