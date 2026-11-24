//
//  ContentView.swift
//  powerNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero
    @State private var closedAIUsageRightWingWidth: CGFloat = 0
    @State private var isAIUsageFlightTransitioning: Bool = false
    @State private var settledAIUsageFlightOpen: Bool = false
    @State private var settledAIUsageOpenTab: NotchViews = .home
    @State private var aiUsageFlightResetTask: Task<Void, Never>?
    @State private var aiUsageFlightHasClosedAnchor: Bool = false
    @State private var aiUsageFlightHasOpenAnchor: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    @Default(.liquidGlassNotch) var liquidGlassNotch

    @Default(.developerClearLiquidGlass) var clearLiquidGlass

    @Default(.dynamicIslandShape) var dynamicIslandShape

    @Default(.displayDynamicIslandShape) var displayDynamicIslandShape

    @Default(.enableLyrics) var enableLyrics

    @Default(.mediaColorStyle) var mediaColorStyle

    @Default(.customMediaColorData) var customMediaColorData

    @Default(.enableAIUsageNotchTab) var enableAIUsageNotchTab

    @Default(.displayDynamicIslandTuning) var displayDynamicIslandTuning

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 1.0, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10
    private let closedLiveActivitySpacing: CGFloat = 8

    private var isLiquidGlassOpen: Bool {
        vm.notchState == .open && liquidGlassNotch
    }

    private var isClosedExpanded: Bool {
        guard vm.notchState == .closed else { return false }
        if coordinator.helloAnimationRunning { return true }
        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && Defaults[.showPowerStatusNotifications]
        {
            return true
        }
        if coordinator.sneakPeek.show
            && (coordinator.sneakPeek.type != .music)
            && (coordinator.sneakPeek.type != .battery)
        {
            return true
        }
        if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            return true
        }
        if !coordinator.expandingView.show && enableAIUsageNotchTab && !vm.hideOnClosed {
            return true
        }
        if !coordinator.expandingView.show
            && (!musicManager.isPlaying && musicManager.isPlayerIdle)
            && Defaults[.showNotHumanFace] && !vm.hideOnClosed
        {
            return true
        }
        if coordinator.sneakPeek.show
            && coordinator.sneakPeek.type == .music
            && !vm.hideOnClosed
            && Defaults[.sneakPeekStyles] == .standard
        {
            return true
        }
        return false
    }

    private var usesDynamicIsland: Bool {
        DisplayNotchSettings.usesDynamicIsland(
            forUUID: vm.screenUUID,
            overrides: displayDynamicIslandShape,
            defaultEnabled: dynamicIslandShape
        )
    }

    private var isDynamicIslandActive: Bool {
        guard usesDynamicIsland else { return false }
        if vm.notchState == .open { return true }
        if isClosedExpanded { return true }
        return vm.effectiveClosedNotchHeight > 0
    }

    private var isFloatingDynamicIsland: Bool {
        !hasPhysicalNotch && isDynamicIslandActive
    }

    private var currentDynamicIslandTuning: DisplayDynamicIslandTuning {
        guard let uuid = vm.screenUUID else { return DisplayDynamicIslandTuning() }
        return displayDynamicIslandTuning[uuid] ?? DisplayDynamicIslandTuning()
    }

    /// Default top clearance below the physical screen top edge for the Dynamic Island.
    /// Zero on all displays so non-notched displays span the full menu bar height by default.
    private var defaultDynamicIslandTopInset: CGFloat {
        0
    }

    /// Effective vertical offset (pt) from the screen's top edge for the Dynamic Island,
    /// combining the display's default clearance with any Developer Options per-display offset.
    private var effectiveDynamicIslandTopOffset: CGFloat {
        guard isDynamicIslandActive else { return 0 }
        guard vm.notchState == .open || vm.effectiveClosedNotchHeight > 0 else { return 0 }
        return defaultDynamicIslandTopInset + CGFloat(currentDynamicIslandTuning.verticalOffset)
    }

    private var dynamicIslandTopPadding: CGFloat {
        max(0, effectiveDynamicIslandTopOffset)
    }

    private var dynamicIslandNegativeYOffset: CGFloat {
        min(0, effectiveDynamicIslandTopOffset)
    }

    private var islandMorph: CGFloat {
        isDynamicIslandActive ? 1.0 : 0.0
    }

    /// Unified concentric outer corner radius for the expanded card in both Hanging Notch
    /// and Dynamic Island modes (R_outer = R_inner + d = 14 + 14 = 28pt scaled, 14 + 10 = 24pt unscaled).
    private var openConcentricOuterRadius: CGFloat {
        Defaults[.cornerRadiusScaling] ? 28 : 24
    }

    /// Unified concentric outer inset d applied identically on all 4 sides in both modes.
    private var openConcentricInset: CGFloat {
        Defaults[.cornerRadiusScaling] ? 14 : 10
    }

    private var topCornerRadius: CGFloat {
        if isDynamicIslandActive {
            if vm.notchState == .open {
                return openConcentricOuterRadius
            }
            if coordinator.helloAnimationRunning {
                return 22
            }
            // Exact concentric outer radius matching the top closed row's circular wings
            // (R_outer = r_inner + d = side/2 + (H_closed - side)/2 = H_closed/2), preserved
            // even when HUD/sneak-peek expands downward so top-left/top-right corners never pinch.
            return max(0, closedVisualHeight / 2)
        }
        guard vm.notchState == .open && Defaults[.cornerRadiusScaling] else {
            return cornerRadiusInsets.closed.top
        }
        return liquidGlassNotch ? openNotchEarMaxInset : cornerRadiusInsets.opened.top
    }

    private var defaultClosedVisualHeight: CGFloat {
        guard vm.effectiveClosedNotchHeight > 0 else { return 0 }
        let physicalHeight = vm.physicalNotchSize?.height ?? 0
        if let screen = vm.screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) ?? NSScreen.main {
            let hmb = DisplayNotchSettings.menuBarHeight(for: screen)
            if hmb > 0 {
                return max(14, physicalHeight, hmb - DisplayNotchSettings.menuBarDefaultHeightTrim)
            }
        }
        return max(14, physicalHeight, vm.effectiveClosedNotchHeight - DisplayNotchSettings.menuBarDefaultHeightTrim)
    }

    private var closedVisualHeight: CGFloat {
        guard vm.effectiveClosedNotchHeight > 0 else { return 0 }
        if isDynamicIslandActive, let customHeight = currentDynamicIslandTuning.totalHeight {
            return max(14, CGFloat(customHeight))
        }
        return defaultClosedVisualHeight
    }

    private var closedLiveActivitySide: CGFloat {
        let baseHeight = closedVisualHeight
        guard baseHeight > 0 else { return 0 }
        let verticalMargin: CGFloat
        if baseHeight <= 21 {
            verticalMargin = max(3.5, baseHeight * 0.24)
        } else {
            verticalMargin = min(12, max(5, baseHeight - 16))
        }
        return max(8, baseHeight - verticalMargin)
    }

    private var closedSideClearance: CGFloat {
        max(2, (closedVisualHeight - closedLiveActivitySide) / 2)
    }

    private var closedIdlePillRadius: CGFloat {
        coordinator.helloAnimationRunning ? 22 : max(0, closedVisualHeight / 2)
    }

    /// Inner spacer width for the collapsed idle state. On displays with a physical camera notch:
    /// - In Dynamic Island mode, wraps the hardware notch in the minimum achievable capsule width
    ///   (`physicalWidth + 2 * R`) so the capsule's straight top edge covers the physical notch's
    ///   widest top flare and both semicircular end caps clear the hardware bezel completely.
    /// - In Hanging Notch mode, sizes the vertical side walls (`innerWidth + 2 * closedSideClearance`)
    ///   to wrap cleanly outside the physical hardware bezel so the exterior glass rim is never clipped.
    private var closedIdleInnerWidth: CGFloat {
        if let physicalWidth = vm.physicalNotchSize?.width, physicalWidth > 0 {
            if isDynamicIslandActive {
                let minPillWidth = physicalWidth + closedIdlePillRadius * 2
                return max(0, minPillWidth - 2 * closedSideClearance)
            }
            let targetWallWidth = max(vm.closedNotchSize.width, physicalWidth + 4)
            return max(0, targetWallWidth - 2 * closedSideClearance)
        }
        return max(0, vm.closedNotchSize.width - 20)
    }

    private var bottomCornerRadius: CGFloat {
        if isDynamicIslandActive {
            return topCornerRadius
        }
        if vm.notchState == .open {
            return openConcentricOuterRadius
        }
        if let physicalHeight = vm.physicalNotchSize?.height,
           physicalHeight > 0,
           !isClosedExpanded
        {
            return min(cornerRadiusInsets.closed.bottom, max(8, physicalHeight * 0.3125))
        }
        return cornerRadiusInsets.closed.bottom
    }

    /// Horizontal width added on each side of the open card for the hanging notch's concave
    /// top meniscus ears so the inner 640pt card body and all child elements sit at identical
    /// screen coordinates in both Dynamic Island and Non-Dynamic Island modes.
    private var openOuterEarWidth: CGFloat {
        guard !usesDynamicIsland else { return 0 }
        guard Defaults[.cornerRadiusScaling] else { return cornerRadiusInsets.closed.top }
        return liquidGlassNotch ? openNotchEarMaxInset : cornerRadiusInsets.opened.top
    }

    private var closedAIUsageEffectiveRightWidth: CGFloat {
        let side = closedLiveActivitySide
        guard enableAIUsageNotchTab else { return side }
        return max(side, closedAIUsageRightWingWidth)
    }

    private var closedAIUsageBalancedLeftWidth: CGFloat {
        let side = closedLiveActivitySide
        guard hasPhysicalNotch && enableAIUsageNotchTab else { return side }
        return max(side, closedAIUsageRightWingWidth)
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (closedAIUsageBalancedLeftWidth + closedAIUsageEffectiveRightWidth + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && enableAIUsageNotchTab && !vm.hideOnClosed
        {
            chinWidth += (closedAIUsageBalancedLeftWidth + closedAIUsageEffectiveRightWidth + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * closedLiveActivitySide + 20)
        } else if vm.notchState == .closed,
            isDynamicIslandActive,
            let physicalWidth = vm.physicalNotchSize?.width,
            physicalWidth > 0
        {
            chinWidth = max(chinWidth, physicalWidth + closedIdlePillRadius * 2)
        }

        return chinWidth
    }

    private var hasPhysicalNotch: Bool {
        (vm.physicalNotchSize?.height ?? 0) > 0
    }

    private var isInlineMusicSneakPeekActive: Bool {
        coordinator.expandingView.show
            && coordinator.expandingView.type == .music
            && Defaults[.sneakPeekStyles] == .inline
    }

    private var hasActiveMusicLyrics: Bool {
        enableLyrics
            && musicManager.isPlaying
            && (!musicManager.syncedLyrics.isEmpty
                || !musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && coordinator.musicLiveActivityEnabled
            && !vm.hideOnClosed
    }

    private var shouldShowClosedLyricsInNotch: Bool {
        vm.notchState == .closed
            && !hasPhysicalNotch
            && hasActiveMusicLyrics
            && !isInlineMusicSneakPeekActive
            && (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
    }

    private var shouldShowClosedLyricsBelowNotch: Bool {
        vm.notchState == .closed
            && hasPhysicalNotch
            && hasActiveMusicLyrics
    }

    private var isShowingMusicClosedLiveActivity: Bool {
        (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled
            && !vm.hideOnClosed
    }

    private var isShowingAIUsageClosedLiveActivity: Bool {
        !coordinator.expandingView.show
            && enableAIUsageNotchTab
            && !vm.hideOnClosed
            && !isShowingMusicClosedLiveActivity
    }

    private var isShowingSpecialClosedOverlay: Bool {
        if coordinator.helloAnimationRunning { return true }
        if coordinator.expandingView.type == .battery
            && coordinator.expandingView.show
            && Defaults[.showPowerStatusNotifications]
        {
            return true
        }
        if coordinator.sneakPeek.show
            && (coordinator.sneakPeek.type != .music)
            && (coordinator.sneakPeek.type != .battery)
        {
            return true
        }
        if coordinator.sneakPeek.show
            && coordinator.sneakPeek.type == .music
            && !vm.hideOnClosed
            && Defaults[.sneakPeekStyles] == .standard
        {
            return true
        }
        if !coordinator.expandingView.show
            && !isShowingMusicClosedLiveActivity
            && !isShowingAIUsageClosedLiveActivity
            && (!musicManager.isPlaying && musicManager.isPlayerIdle)
            && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            return true
        }
        return false
    }

    private var closedHorizontalPadding: CGFloat {
        isDynamicIslandActive
            ? closedSideClearance
            : (cornerRadiusInsets.closed.top + closedSideClearance)
    }

    private var closedAnimatedWidth: CGFloat {
        let side = closedLiveActivitySide
        let gestureRightMin = max(0, side + gestureProgress / 2)
        if isShowingMusicClosedLiveActivity {
            let centerW: CGFloat = isInlineMusicSneakPeekActive
                ? 380
                : max(0, vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
            let rightW = enableAIUsageNotchTab
                ? max(closedAIUsageEffectiveRightWidth, gestureRightMin)
                : gestureRightMin
            return closedAIUsageBalancedLeftWidth
                + centerW
                + rightW
                + closedLiveActivitySpacing * 2
                + closedHorizontalPadding * 2
        }
        if isShowingAIUsageClosedLiveActivity {
            let centerW = max(0, vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
            let rightW = max(closedAIUsageEffectiveRightWidth, gestureRightMin)
            return closedAIUsageBalancedLeftWidth
                + centerW
                + rightW
                + closedLiveActivitySpacing * 2
                + closedHorizontalPadding * 2
        }
        return closedIdleInnerWidth + closedHorizontalPadding * 2
    }

    private var isShowingClosedAIUsageSummaryInCenter: Bool {
        vm.notchState == .closed
            && !hasPhysicalNotch
            && isShowingAIUsageClosedLiveActivity
    }

    private var shouldShowFluidMusicRim: Bool {
        enableAIUsageNotchTab && musicManager.isPlaying
    }

    private var resolvedFluidMusicRimColor: NSColor {
        switch mediaColorStyle {
        case .systemDefault:
            return .white
        case .albumArt:
            return musicManager.avgColor
        case .custom:
            return MediaColorStyle.resolvedCustomNSColor(from: customMediaColorData)
        }
    }

    private var resolvedSpectrumColor: Color {
        switch mediaColorStyle {
        case .systemDefault:
            return notchInk.secondary(0.65)
        case .albumArt:
            return notchInk.tinted(musicManager.avgColor, darkMinBrightness: 0.5)
        case .custom:
            let custom = MediaColorStyle.resolvedCustomNSColor(from: customMediaColorData)
            return notchInk.tinted(custom, darkMinBrightness: 0.5)
        }
    }

    private var usesClearGlassForeground: Bool {
        liquidGlassNotch && clearLiquidGlass && (vm.notchState == .open || !hasPhysicalNotch)
    }

    private var notchInk: NotchGlassInk {
        NotchGlassInk(isClearGlass: usesClearGlassForeground)
    }

    private var isAIUsageFlightActive: Bool {
        guard enableAIUsageNotchTab else { return false }
        let isOpen = vm.notchState == .open
        let inFlight = isAIUsageFlightTransitioning || (isOpen != settledAIUsageFlightOpen)
        guard inFlight else { return false }
        let activeTab = isOpen ? coordinator.currentView : settledAIUsageOpenTab
        guard activeTab == .aiUsage else { return false }
        if isOpen {
            return aiUsageFlightHasClosedAnchor
        } else {
            return aiUsageFlightHasOpenAnchor && aiUsageFlightHasClosedAnchor
        }
    }

    private func handleAIUsageNotchStateChange(_ newState: NotchState) {
        aiUsageFlightResetTask?.cancel()
        let newIsOpen = newState == .open
        let activeTab = newIsOpen ? coordinator.currentView : settledAIUsageOpenTab
        if newIsOpen {
            settledAIUsageOpenTab = coordinator.currentView
        }
        let canAnimate: Bool = enableAIUsageNotchTab
            && activeTab == .aiUsage
            && (newIsOpen
                ? aiUsageFlightHasClosedAnchor
                : (aiUsageFlightHasOpenAnchor && aiUsageFlightHasClosedAnchor))

        guard canAnimate else {
            isAIUsageFlightTransitioning = false
            settledAIUsageFlightOpen = newIsOpen
            return
        }

        isAIUsageFlightTransitioning = true
        let duration = newIsOpen ? NotchLyricMotion.openFlightDuration : NotchLyricMotion.closeFlightDuration
        let settleMs = Int((duration * 1000).rounded()) + 30
        aiUsageFlightResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(settleMs))
            guard !Task.isCancelled else { return }
            settledAIUsageFlightOpen = (vm.notchState == .open)
            isAIUsageFlightTransitioning = false
        }
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        let isNotchVisible = vm.notchState == .open || vm.effectiveClosedNotchHeight > 0
        let showFluidRim = shouldShowFluidMusicRim && isNotchVisible
        let showBaseGlassRim = liquidGlassNotch && isNotchVisible && !showFluidRim

        // Unified open insets: both Hanging Notch and Dynamic Island share identical inner
        // content coordinates (d = 14pt scaled / 10pt unscaled from the 640×226 main card body).
        let openHorizontalPadding: CGFloat = openConcentricInset + openOuterEarWidth
        let openOuterWidth: CGFloat = openNotchSize.width + openOuterEarWidth * 2
        let openTopInnerPadding: CGFloat = openConcentricInset
        let openBottomInnerPadding: CGFloat = openConcentricInset

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .environment(\.colorScheme, usesClearGlassForeground ? .light : .dark)
                    .frame(
                        maxWidth: vm.notchState == .open ? .infinity : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        vm.notchState == .open ? openHorizontalPadding : closedHorizontalPadding
                    )
                    .padding(.top, vm.notchState == .open ? openTopInnerPadding : 0)
                    .padding(
                        .bottom,
                        vm.notchState == .open ? openBottomInnerPadding : 0
                    )
                    .modifier(NotchCardSurface(
                        openProgress: vm.notchState == .open ? 1 : 0,
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius,
                        islandMorph: islandMorph,
                        closedWidth: closedAnimatedWidth,
                        openWidth: openOuterWidth,
                        useAnimatedClosedWidth: !isShowingSpecialClosedOverlay,
                        isOpen: vm.notchState == .open,
                        openHeight: openNotchSize.height,
                        fallbackClosedSize: CGSize(
                            width: closedAnimatedWidth,
                            height: closedVisualHeight
                        ),
                        useLiquidGlass: liquidGlassNotch,
                        physicalNotchSize: vm.physicalNotchSize,
                        isVisible: isNotchVisible,
                        showBaseGlassRim: showBaseGlassRim,
                        showFluidMusicRim: showFluidRim,
                        themeColor: resolvedFluidMusicRimColor
                    ))
                    .conditionalModifier(!liquidGlassNotch) { view in
                        view
                            .shadow(
                                color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                                    ? .black.opacity(0.7) : .clear,
                                radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                            )
                    }
                    .overlay(alignment: .top) {
                        if !liquidGlassNotch && !isFloatingDynamicIsland {
                            Rectangle()
                                .fill(.black)
                                .frame(height: 1)
                                .padding(.horizontal, topCornerRadius)
                        } else if let physicalWidth = vm.physicalNotchSize?.width,
                                  physicalWidth > 0,
                                  isNotchVisible,
                                  effectiveDynamicIslandTopOffset <= 0
                        {
                            Rectangle()
                                .fill(.black)
                                .frame(width: physicalWidth, height: 1)
                        }
                    }
                    .padding(.top, dynamicIslandTopPadding)
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 && vm.notchState == .closed ? 10 : 0
                    )
                
                mainLayout
                    .conditionalModifier(true) { view in
                        return view
                            .animation(
                                vm.notchState == .open
                                    ? NotchLyricMotion.openAnimation
                                    : NotchLyricMotion.closeAnimation,
                                value: vm.notchState
                            )
                            .animation(.smooth, value: gestureProgress)
                            .animation(
                                enableAIUsageNotchTab
                                    ? NotchLyricMotion.openAnimation
                                    : NotchLyricMotion.closeAnimation,
                                value: enableAIUsageNotchTab
                            )
                            .animation(NotchLyricMotion.openAnimation, value: isDynamicIslandActive)
                            .animation(NotchLyricMotion.openAnimation, value: closedAnimatedWidth)
                            .animation(.smooth, value: musicManager.isPlaying)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if shouldShowClosedLyricsBelowNotch {
                    Color.clear
                        .frame(width: computedChinWidth, height: 20)
                        .anchorPreference(key: NotchLyricAnchorKey.self, value: .bounds) {
                            NotchLyricAnchors(closed: $0)
                        }
                }
                let effectiveChinHeight = max(
                    0,
                    vm.chinHeight - max(0, closedVisualHeight - vm.effectiveClosedNotchHeight)
                )
                if effectiveChinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: effectiveChinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .overlayPreferenceValue(NotchLyricAnchorKey.self) { anchors in
            let activeLyrics = hasActiveMusicLyrics
            let showClosedLyrics = shouldShowClosedLyricsBelowNotch || shouldShowClosedLyricsInNotch
            let showOpenLyrics = vm.notchState == .open
                && enableLyrics
                && coordinator.currentView == .home
            let showBottomEdgeOpenLyrics = vm.notchState == .open
                && coordinator.currentView != .home
                && activeLyrics

            GeometryReader { proxy in
                NotchUnifiedLyricOverlay(
                    anchors: anchors,
                    proxy: proxy,
                    isOpen: vm.notchState == .open,
                    isHomeTab: coordinator.currentView == .home,
                    showClosedLyrics: showClosedLyrics,
                    showOpenLyrics: showOpenLyrics,
                    showBottomEdgeOpenLyrics: showBottomEdgeOpenLyrics,
                    isLiquidGlass: liquidGlassNotch,
                    gestureProgress: gestureProgress,
                    isClosedInlineInNotch: !hasPhysicalNotch,
                    topOffset: dynamicIslandTopPadding
                )
            }
            .allowsHitTesting(false)
        }
        .overlayPreferenceValue(NotchAIUsageAnchorKey.self) { anchors in
            GeometryReader { proxy in
                NotchAIUsageFlightOverlay(
                    anchors: anchors,
                    proxy: proxy,
                    isOpen: vm.notchState == .open,
                    isAIUsageTab: coordinator.currentView == .aiUsage,
                    isFlightActive: isAIUsageFlightActive,
                    gestureProgress: gestureProgress,
                    hasClosedAnchor: $aiUsageFlightHasClosedAnchor,
                    hasOpenAnchor: $aiUsageFlightHasOpenAnchor
                )
            }
            .allowsHitTesting(false)
        }
        .offset(y: dynamicIslandNegativeYOffset)
        .conditionalModifier(gestureProgress != 0 || !liquidGlassNotch) { view in
            view.compositingGroup()
        }
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .overlay {
            if liquidGlassNotch {
                NotchCursorOcclusionView(
                    isEnabled: isLiquidGlassOpen && !vm.anyDropZoneTargeting && !vm.isBatteryPopoverActive,
                    physicalNotchSize: vm.physicalNotchSize,
                    activeNotchSize: CGSize(width: openOuterWidth, height: openNotchSize.height),
                    onPointerExitedNotch: {
                        handleHover(false)
                    }
                )
                .frame(width: windowSize.width, height: windowSize.height)
                .transaction { $0.animation = nil }
                .allowsHitTesting(false)
            }
        }
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environment(\.notchGlassInk, notchInk)
        .environment(\.isAIUsageFlightActive, isAIUsageFlightActive)
        .environmentObject(vm)
        .onAppear {
            settledAIUsageFlightOpen = (vm.notchState == .open)
            settledAIUsageOpenTab = coordinator.currentView
        }
        .onChange(of: vm.notchState) { _, newState in
            handleAIUsageNotchStateChange(newState)
        }
        .onChange(of: coordinator.currentView) { _, newView in
            guard vm.notchState == .open else { return }
            settledAIUsageOpenTab = newView
            if newView != .aiUsage {
                aiUsageFlightResetTask?.cancel()
                isAIUsageFlightTransitioning = false
                settledAIUsageFlightOpen = true
            }
        }
        .onPreferenceChange(ClosedAIUsageRightWingWidthKey.self) { width in
            guard gestureProgress == 0, width > 0, abs(width - closedAIUsageRightWingWidth) > 0.5 else { return }
            closedAIUsageRightWingWidth = width
        }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen(usePointerSideTab: false)
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    private var closedRowHeight: CGFloat {
        closedVisualHeight
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(notchInk.primary(1.0))
                            }

                            Rectangle()
                                .fill(liquidGlassNotch ? .clear : .black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: closedRowHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress, rowHeight: closedRowHeight)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && enableAIUsageNotchTab && !vm.hideOnClosed {
                          AIUsageClosedLiveActivity()
                              .frame(alignment: .center)
                              .transition(.opacity)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: NotchHeaderMetrics.controlHeight)
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: closedIdleInnerWidth, height: closedRowHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.horizontal, 4)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(
                                              .constant(musicManager.songTitle + " - " + musicManager.artistName),
                                              textColor: notchInk.secondary(0.65),
                                              minDuration: 1,
                                              frameWidth: geo.size.width
                                          )
                                      }
                                  }
                                  .foregroundStyle(notchInk.secondary(0.65))
                                  .padding(.horizontal, 4)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .aiUsage:
                        NotchAIUsageView()
                    }
                }
                // The outer card already animates layout; a second scale makes the body drift.
                .transition(.opacity)
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    private func closedAlbumArtThumbnail(side: CGFloat) -> some View {
        let closedInset = max(4, (closedVisualHeight - side) / 2)
        let closedArtRadius: CGFloat = isDynamicIslandActive
            ? (side / 2)
            : max(4, cornerRadiusInsets.closed.bottom - closedInset)
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: closedArtRadius,
                    style: .continuous
                )
            )
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .frame(
                width: side,
                height: side
            )
    }

    @ViewBuilder
    private func closedAIUsageRightWing(side: CGFloat) -> some View {
        ClosedNotchAIUsageRingView(containerSide: side)
            .frame(
                minWidth: max(0, side + gestureProgress / 2),
                minHeight: side,
                maxHeight: side,
                alignment: .center
            )
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ClosedAIUsageRightWingWidthKey.self,
                        value: geo.size.width
                    )
                }
            }
    }

    @ViewBuilder
    func AIUsageClosedLiveActivity() -> some View {
        let side = closedLiveActivitySide
        HStack(spacing: closedLiveActivitySpacing) {
            closedAlbumArtThumbnail(side: side)
                .frame(width: closedAIUsageBalancedLeftWidth, height: side, alignment: .leading)

            Rectangle()
                .fill(liquidGlassNotch ? .clear : .black)
                .overlay {
                    if !hasPhysicalNotch {
                        ClosedNotchAIUsageSummaryView(closedHeight: closedVisualHeight)
                    }
                }
                .frame(width: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top)

            closedAIUsageRightWing(side: side)
        }
        .frame(
            height: closedRowHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: closedLiveActivitySide,
                        height: closedLiveActivitySide
                    )
                Rectangle()
                    .fill(liquidGlassNotch ? .clear : .black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: closedRowHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        let side = closedLiveActivitySide
        HStack(spacing: closedLiveActivitySpacing) {
            closedAlbumArtThumbnail(side: side)
                .frame(width: closedAIUsageBalancedLeftWidth, height: side, alignment: .leading)

            Rectangle()
                .fill(liquidGlassNotch ? .clear : .black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: notchInk.secondary(0.65),
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(notchInk.secondary(0.65))
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )
                .conditionalModifier(shouldShowClosedLyricsInNotch) { view in
                    view.anchorPreference(key: NotchLyricAnchorKey.self, value: .bounds) {
                        NotchLyricAnchors(closed: $0)
                    }
                }

            if enableAIUsageNotchTab {
                closedAIUsageRightWing(side: side)
            } else {
                HStack {
                    if useMusicVisualizer {
                        Rectangle()
                            .fill(resolvedSpectrumColor.gradient)
                            .frame(width: 50, alignment: .center)
                            .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                            .mask {
                                AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                    .frame(
                                        width: min(22, max(10, side * 0.85)),
                                        height: min(16, max(8, side * 0.65))
                                    )
                            }
                    } else {
                        LottieAnimationContainer()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(
                    width: max(
                        0,
                        side + gestureProgress / 2
                    ),
                    height: side,
                    alignment: .center
                )
            }
        }
        .frame(
            height: closedRowHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func preferredTabForPointerLocation(
        _ mouseLocation: NSPoint = NSEvent.mouseLocation
    ) -> NotchViews? {
        guard enableAIUsageNotchTab,
              !coordinator.openLastTabByDefault,
              let screenFrame = getScreenFrame(vm.screenUUID) ?? NSScreen.main?.frame
        else {
            return nil
        }

        let centerWidth: CGFloat = isInlineMusicSneakPeekActive
            ? 380
            : max(0, vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
        let centerHalfWidth = centerWidth / 2
        let centerShiftX: CGFloat = (closedAIUsageBalancedLeftWidth - closedAIUsageEffectiveRightWidth) / 2
        let offsetFromCenter = mouseLocation.x - (screenFrame.midX + centerShiftX)

        if offsetFromCenter < -centerHalfWidth {
            return .home
        }
        if offsetFromCenter > centerHalfWidth {
            return .aiUsage
        }

        // Pointer is in the center region: match what is currently displayed in the center.
        if shouldShowClosedLyricsInNotch || shouldShowClosedLyricsBelowNotch || isInlineMusicSneakPeekActive {
            return .home
        }
        if isShowingClosedAIUsageSummaryInCenter {
            return .aiUsage
        }

        return offsetFromCenter >= 0 ? .aiUsage : .home
    }

    private func doOpen(usePointerSideTab: Bool = true) {
        if usePointerSideTab,
           vm.notchState == .closed,
           let targetTab = preferredTabForPointerLocation()
        {
            coordinator.currentView = targetTab
        }
        withAnimation(NotchLyricMotion.openAnimation) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed {
                HapticFeedbackLevel.performConfigured()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            // AppKit synthesizes a spurious mouseExited (onHover(false)) whenever SkyLight
            // hides the hardware cursor inside the open notch's dark transition zone.
            if vm.notchState == .open && (SkyLightCursorController.shared.isHidden || vm.isMouseHovering()) {
                return
            }

            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    if self.vm.notchState == .open && (SkyLightCursorController.shared.isHidden || self.vm.isMouseHovering()) {
                        return
                    }

                    withAnimation(NotchLyricMotion.closeAnimation) {
                        self.isHovering = false
                        if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                            self.vm.close()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            HapticFeedbackLevel.performConfigured()
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar && coordinator.currentView != .aiUsage else {
            if gestureProgress != .zero {
                withAnimation(animationSpring) {
                    gestureProgress = .zero
                }
            }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(NotchLyricMotion.closeAnimation) {
                isHovering = false
                if !SharingStateManager.shared.preventNotchClose {
                    gestureProgress = .zero
                    vm.close()
                }
            }

            HapticFeedbackLevel.performConfigured()
        }
    }
}

private struct ClosedAIUsageRightWingWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
