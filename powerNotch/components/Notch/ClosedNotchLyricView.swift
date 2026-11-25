//
//  ClosedNotchLyricView.swift
//  powerNotch
//
//

import SwiftUI
import Defaults

/// Shared motion timing constants and curves synchronizing the notch expansion,
/// album-art thumbnail `matchedGeometryEffect`, and unified lyric flight so every
/// element arrives on the exact same frame.
enum NotchLyricMotion {
    static var animationSpeed: Double {
        let speed = Defaults[.developerAnimationSpeed]
        return speed.isFinite ? min(2, max(0.1, speed)) : 1
    }

    static var openFlightDuration: Double { 0.38 / animationSpeed }
    static var closeFlightDuration: Double { 0.36 / animationSpeed }

    static var openAnimation: Animation {
        .timingCurve(0.22, 1.0, 0.36, 1.0, duration: openFlightDuration)
    }

    static var closeAnimation: Animation {
        .timingCurve(0.22, 1.0, 0.36, 1.0, duration: closeFlightDuration)
    }
}

/// Anchors reported by the closed-notch lyric slot (below the notch) and the
/// expanded-notch lyric slot (below the artist name) so a single unified lyric
/// element can smoothly glide between both positions on open and close.
struct NotchLyricAnchors {
    var closed: Anchor<CGRect>? = nil
    var open: Anchor<CGRect>? = nil
}

struct NotchLyricAnchorKey: PreferenceKey {
    static let defaultValue = NotchLyricAnchors()

    static func reduce(value: inout NotchLyricAnchors, nextValue: () -> NotchLyricAnchors) {
        let next = nextValue()
        if let closed = next.closed {
            value.closed = closed
        }
        if let open = next.open {
            value.open = open
        }
    }
}

private enum NotchLyricDisplayMode: Equatable {
    case closed
    case openHome
    case openBottomEdge
}

private enum LyricScrollPhase: Equatable {
    case idle
    case leadingHold
    case scrolling
    case trailingHold
}

/// Single continuously-mounted lyric view rendered in the fixed `windowSize` overlay of
/// `ContentView`, smoothly translating between the closed-notch strip below the notch,
/// the expanded-notch bottom edge (when on non-Home tabs), and the expanded-notch slot
/// beneath the artist name (when on the Home tab) with zero overshoot.
struct NotchUnifiedLyricOverlay: View {
    @ObservedObject var musicManager = MusicManager.shared

    let anchors: NotchLyricAnchors
    let proxy: GeometryProxy
    let isOpen: Bool
    let isHomeTab: Bool
    let showClosedLyrics: Bool
    let showOpenLyrics: Bool
    let showBottomEdgeOpenLyrics: Bool
    @Environment(\.notchGlassInk) private var ink
    @Default(.mediaColorStyle) private var mediaColorStyle
    @Default(.customMediaColorData) private var customMediaColorData
    let isLiquidGlass: Bool
    let gestureProgress: CGFloat
    var isClosedInlineInNotch: Bool = false
    var topOffset: CGFloat = 0

    @State private var settledClosedRect: CGRect = .zero
    @State private var settledOpenRect: CGRect = .zero
    @State private var lastValidRect: CGRect = .zero
    @State private var settledIsOpen: Bool = false
    @State private var isTransitioning: Bool = false
    @State private var lastTransitionWasTabSwitch: Bool = false
    @State private var hasMounted: Bool = false
    @State private var transitionResetTask: Task<Void, Never>?
    @State private var wasVisible: Bool = false
    @State private var measuredTextWidth: CGFloat = 0
    @State private var marqueeOffset: CGFloat = 0
    @State private var scrollPhase: LyricScrollPhase = .idle
    @State private var marqueeTask: Task<Void, Never>?

    private let openAnimation = NotchLyricMotion.openAnimation
    private let closeAnimation = NotchLyricMotion.closeAnimation
    private let tabSwitchAnimation = Animation.spring(response: 0.30, dampingFraction: 0.82)

    private var displayMode: NotchLyricDisplayMode {
        guard isOpen else { return .closed }
        return isHomeTab ? .openHome : .openBottomEdge
    }

    private var isInlineOpen: Bool {
        displayMode == .openHome
    }

    private var currentClosedRect: CGRect? {
        guard showClosedLyrics, let anchor = anchors.closed else { return nil }
        let raw = proxy[anchor]
        guard raw.width > 0, raw.height > 0 else { return nil }
        // Inset horizontally in closed mode so text keeps comfortable breathing room on each side.
        return raw.insetBy(dx: isClosedInlineInNotch ? 4 : 12, dy: 0)
    }

    private var currentOpenRect: CGRect? {
        guard showOpenLyrics, let anchor = anchors.open else { return nil }
        let raw = proxy[anchor]
        guard raw.width > 0, raw.height > 0 else { return nil }
        return raw
    }

    private var openBottomEdgeRect: CGRect {
        let width = max(120, openNotchSize.width - 112)
        let height: CGFloat = 20
        return CGRect(
            x: (proxy.size.width - width) / 2,
            y: openNotchSize.height + topOffset,
            width: width,
            height: height
        )
    }

    private var isInFlight: Bool {
        isTransitioning || (isOpen != settledIsOpen)
    }

    private var isVisible: Bool {
        switch displayMode {
        case .closed:
            return showClosedLyrics
        case .openHome:
            return showOpenLyrics && musicManager.isPlaying
        case .openBottomEdge:
            return showBottomEdgeOpenLyrics
        }
    }

    private var closedLyricColor: Color {
        switch mediaColorStyle {
        case .systemDefault:
            return .white
        case .albumArt:
            return Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.85)
        case .custom:
            let custom = MediaColorStyle.resolvedCustomNSColor(from: customMediaColorData)
            return Color(nsColor: custom).ensureMinimumBrightness(factor: 0.85)
        }
    }

    private var openLyricColor: Color {
        if musicManager.isFetchingLyrics {
            return isLiquidGlass ? ink.tertiary(0.50) : Color.gray.opacity(0.7)
        }
        return isLiquidGlass ? ink.secondary(0.68) : Color.gray
    }

    private var activeFlightAnimation: Animation? {
        // Settings can reveal a new anchor while the card stays closed. Snap to that
        // anchor instead of flying from the last visible (possibly expanded) position.
        // Position flights belong only to card expansion/collapse and open-tab changes.
        guard hasMounted && isInFlight && (wasVisible || isVisible) else { return nil }
        if isOpen != settledIsOpen {
            return isOpen ? openAnimation : closeAnimation
        }
        if lastTransitionWasTabSwitch {
            return tabSwitchAnimation
        }
        return isOpen ? openAnimation : closeAnimation
    }

    var body: some View {
        // Lock endpoints to settled rects during open/close transitions (including frame 0)
        // in the static `windowSize` coordinate space so container resizing never drags the
        // target mid-flight and produces overshoot.
        let inFlight = isInFlight
        let closedRect: CGRect = {
            if inFlight && settledClosedRect.width > 0 {
                return settledClosedRect
            }
            return currentClosedRect ?? settledClosedRect
        }()
        let openHomeRect: CGRect = {
            if inFlight && settledOpenRect.width > 0 {
                return settledOpenRect
            }
            return currentOpenRect ?? settledOpenRect
        }()
        let targetRect: CGRect = {
            switch displayMode {
            case .closed:
                if closedRect.width > 0 && closedRect.height > 0 {
                    return closedRect
                }
                return lastValidRect
            case .openHome:
                if openHomeRect.width > 0 && openHomeRect.height > 0 {
                    return openHomeRect
                }
                return lastValidRect.width > 0 ? lastValidRect : openBottomEdgeRect
            case .openBottomEdge:
                return openBottomEdgeRect
            }
        }()
        let targetInlineProgress: CGFloat = isInlineOpen ? 1.0 : 0.0
        let flightAnim = activeFlightAnimation

        Group {
            if targetRect.width > 0 && targetRect.height > 0 {
                lyricFlightTimeline(
                    targetRect: targetRect,
                    targetInlineProgress: targetInlineProgress,
                    flightAnimation: flightAnim
                )
                .animation(.easeInOut(duration: 0.18)) { view in
                    view.opacity(
                        isVisible
                            ? (gestureProgress != 0 && isOpen ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                            : 0.0
                    )
                }
                .onChange(of: targetRect) { _, newRect in
                    if newRect.width > 0 && newRect.height > 0 {
                        lastValidRect = newRect
                    }
                }
                .onChange(of: isOpen) { _, _ in
                    lastTransitionWasTabSwitch = false
                    beginTransitionWindow()
                }
                .onChange(of: isHomeTab) { _, _ in
                    guard isOpen else { return }
                    lastTransitionWasTabSwitch = true
                    beginTransitionWindow(duration: 0.34)
                }
                .onChange(of: isTransitioning) { _, transitioning in
                    finishTransition(transitioning)
                }
                .onChange(of: showBottomEdgeOpenLyrics) { _, _ in
                    if !isInFlight {
                        wasVisible = isVisible
                    }
                }
                .onChange(of: currentClosedRect) { _, newRect in
                    updateClosedPosition(newRect)
                }
                .onChange(of: currentOpenRect) { _, newRect in
                    updateOpenPosition(newRect)
                }
                .onAppear {
                    mountOverlay(at: targetRect)
                }
                .onDisappear(perform: unmountOverlay)
            }
        }
        .allowsHitTesting(false)
    }

    private func finishTransition(_ transitioning: Bool) {
        guard !transitioning else { return }
        settledIsOpen = isOpen
        lastTransitionWasTabSwitch = false
        if isOpen {
            if isHomeTab, let rect = currentOpenRect {
                settledOpenRect = rect
            }
        } else {
            if let rect = currentClosedRect {
                settledClosedRect = rect
            } else if !showClosedLyrics {
                settledClosedRect = .zero
            }
        }
        wasVisible = isVisible
    }

    private func updateClosedPosition(_ newRect: CGRect?) {
        if !isInFlight && !isOpen {
            if let newRect {
                settledClosedRect = newRect
            } else if !showClosedLyrics {
                settledClosedRect = .zero
            }
        } else if settledClosedRect == .zero, let newRect, !isOpen {
            settledClosedRect = newRect
        }
        wasVisible = isVisible
    }

    private func updateOpenPosition(_ newRect: CGRect?) {
        if !isInFlight && isOpen && isHomeTab, let newRect {
            settledOpenRect = newRect
        }
        wasVisible = isVisible
    }

    private func mountOverlay(at targetRect: CGRect) {
        settledIsOpen = isOpen
        if let rect = currentClosedRect {
            settledClosedRect = rect
        }
        if let rect = currentOpenRect {
            settledOpenRect = rect
        }
        if targetRect.width > 0 && targetRect.height > 0 {
            lastValidRect = targetRect
        }
        wasVisible = isVisible
        hasMounted = true
    }

    private func unmountOverlay() {
        transitionResetTask?.cancel()
        transitionResetTask = nil
        marqueeTask?.cancel()
        marqueeTask = nil
        hasMounted = false
    }

    private func lyricFlightTimeline(
        targetRect: CGRect,
        targetInlineProgress: CGFloat,
        flightAnimation: Animation?
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let line = currentLyricLine(at: timeline.date)
            let isPersian = containsPersianCharacters(line)
            let baseFontSize = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
            let adaptiveFontSize: CGFloat = (!isOpen && isClosedInlineInNotch && targetRect.height > 0 && targetRect.height < 20)
                ? max(8.5, targetRect.height * 0.56)
                : baseFontSize
            let font: Font = isPersian
                ? .custom("Vazirmatn-Regular", size: adaptiveFontSize)
                : .system(size: adaptiveFontSize)
            let activeContainerWidth = targetRect.width
            let isOverflowing = measuredTextWidth > activeContainerWidth + 2
            let needsInlineMarquee = isInlineOpen && isOverflowing
            let needsClosedScroll = !isInlineOpen && isOverflowing

            NotchLyricFlightView(
                rect: targetRect,
                inlineProgress: targetInlineProgress,
                measuredTextWidth: measuredTextWidth,
                needsInlineMarquee: needsInlineMarquee,
                needsClosedScroll: needsClosedScroll,
                scrollPhase: scrollPhase,
                marqueeOffset: marqueeOffset
            ) {
                ZStack(alignment: .leading) {
                    lyricTextView(line: line, font: font, needsMarquee: isOverflowing)
                        .overlay(alignment: .leading) {
                            if needsInlineMarquee {
                                lyricTextView(line: line, font: font, needsMarquee: true)
                                    .offset(x: measuredTextWidth + 24)
                            }
                        }
                }
            }
            .animation(flightAnimation, value: targetRect)
            .animation(flightAnimation, value: targetInlineProgress)
            .background {
                lyricWidthMeasurement(
                    line: line,
                    font: font,
                    containerWidth: activeContainerWidth,
                    at: timeline.date
                )
            }
        }
    }

    private func lyricWidthMeasurement(
        line: String,
        font: Font,
        containerWidth: CGFloat,
        at date: Date
    ) -> some View {
        // Measure single-line natural width without affecting layout
        Text(line)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background {
                GeometryReader { textGeo in
                    Color.clear
                        .onAppear {
                            updateMeasuredWidth(
                                textGeo.size.width,
                                line: line,
                                containerWidth: containerWidth,
                                at: date
                            )
                        }
                        .onChange(of: textGeo.size.width) { _, newWidth in
                            updateMeasuredWidth(
                                newWidth,
                                line: line,
                                containerWidth: containerWidth,
                                at: date
                            )
                        }
                        .onChange(of: line) { _, newLine in
                            updateMeasuredWidth(
                                textGeo.size.width,
                                line: newLine,
                                containerWidth: containerWidth,
                                at: date
                            )
                        }
                        .onChange(of: displayMode) { _, _ in
                            updateMeasuredWidth(
                                textGeo.size.width,
                                line: line,
                                containerWidth: containerWidth,
                                at: date
                            )
                        }
                        .onChange(of: containerWidth) { oldWidth, newWidth in
                            guard abs(newWidth - oldWidth) > 0.5 else { return }
                            updateMeasuredWidth(
                                textGeo.size.width,
                                line: line,
                                containerWidth: newWidth,
                                at: date
                            )
                        }
                        .onChange(of: isVisible) { _, visible in
                            guard visible else { return }
                            updateMeasuredWidth(
                                textGeo.size.width,
                                line: line,
                                containerWidth: containerWidth,
                                at: date
                            )
                        }
                }
            }
    }

    private func beginTransitionWindow(duration: Double? = nil) {
        isTransitioning = true
        transitionResetTask?.cancel()
        let flightDuration = duration ?? max(NotchLyricMotion.openFlightDuration, NotchLyricMotion.closeFlightDuration)
        let settleMs = Int((flightDuration * 1000).rounded()) + 30
        transitionResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(settleMs))
            guard !Task.isCancelled else { return }
            // Flip `isTransitioning` so `.onChange(of: isTransitioning)` syncs using the
            // live post-animation `currentOpenRect` / `currentClosedRect` (not a stale struct copy).
            isTransitioning = false
        }
    }

    @ViewBuilder
    private func lyricTextView(line: String, font: Font, needsMarquee: Bool) -> some View {
        Text(line)
            .font(font)
            .foregroundColor(isInlineOpen ? openLyricColor : closedLyricColor)
            .animation(.easeOut(duration: 0.24), value: isInlineOpen)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: needsMarquee, vertical: false)
            .id(line)
            .transition(.opacity)
            .animation(.easeInOut(duration: musicManager.syncedLyrics.isEmpty ? 0.5 : 0.28), value: line)
    }

    private func updateMeasuredWidth(
        _ width: CGFloat,
        line: String,
        containerWidth: CGFloat,
        at date: Date
    ) {
        measuredTextWidth = width
        marqueeTask?.cancel()
        marqueeTask = nil

        let overflow = width - containerWidth
        let shouldScroll = overflow > 2 && !line.isEmpty && containerWidth > 0
        guard shouldScroll else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                marqueeOffset = 0
                scrollPhase = .idle
            }
            return
        }

        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            marqueeOffset = 0
            scrollPhase = .leadingHold
        }

        if isInlineOpen {
            let travelDistance = width + 24
            let duration = max(3.0, Double(travelDistance / 32.0))

            marqueeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollPhase = .scrolling
                }
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    marqueeOffset = -travelDistance
                }
            }
        } else {
            let elapsed = musicManager.estimatedPlaybackPosition(at: date)
            let rawWindow = musicManager.lyricLineRemainingDuration(at: elapsed) ?? 6.0
            let effectiveWindow = min(12.0, max(1.2, rawWindow))
            let leadDelay = min(0.65, max(0.22, effectiveWindow * 0.16))
            let tailHold = min(0.55, max(0.20, effectiveWindow * 0.14))
            let availableScroll = max(0.75, effectiveWindow - leadDelay - tailHold)

            // Smooth readable pace (28...140 pt/s) timed to reveal the full line before the next lyric
            let minDuration = Double(overflow) / 140.0
            let maxDuration = Double(overflow) / 28.0
            let scrollDuration = max(0.55, min(maxDuration, max(minDuration, availableScroll)))

            marqueeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(leadDelay))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    scrollPhase = .scrolling
                }
                withAnimation(.timingCurve(0.25, 0.0, 0.75, 1.0, duration: scrollDuration)) {
                    marqueeOffset = -overflow
                }
                try? await Task.sleep(for: .seconds(scrollDuration))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    scrollPhase = .trailingHold
                }
            }
        }
    }

    private func currentLyricLine(at date: Date) -> String {
        if musicManager.isFetchingLyrics {
            return isInlineOpen ? "Loading lyrics…" : ""
        }
        if !musicManager.syncedLyrics.isEmpty {
            let elapsed = musicManager.estimatedPlaybackPosition(at: date)
            return musicManager.lyricLine(at: elapsed)
        }
        let plain = plainLyricLine(at: date)
        if plain.isEmpty {
            return isInlineOpen ? "No lyrics found" : ""
        }
        return plain
    }

    private func containsPersianCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return v >= 0x0600 && v <= 0x06FF
        }
    }

    /// For plain lyrics: split into lines and cycle every ~6 seconds
    private func plainLyricLine(at date: Date) -> String {
        let plain = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return "" }
        let lines = plain.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }
        let secondsSinceRef = date.timeIntervalSinceReferenceDate
        let index = Int(secondsSinceRef / 6.0) % lines.count
        return lines[index]
    }
}

/// Pure `Animatable` flight container for the unified lyric view.
/// Smoothly interpolates position, clipping frame, shadow strength, and horizontal text
/// alignment (centered below the notch ↔ leading-aligned under the artist name) with zero overshoot.
private struct NotchLyricFlightView<Content: View>: View, Animatable {
    var midX: CGFloat
    var midY: CGFloat
    var boxWidth: CGFloat
    var boxHeight: CGFloat
    var inlineProgress: CGFloat
    let measuredTextWidth: CGFloat
    let needsInlineMarquee: Bool
    let needsClosedScroll: Bool
    let scrollPhase: LyricScrollPhase
    let marqueeOffset: CGFloat
    let content: Content

    init(
        rect: CGRect,
        inlineProgress: CGFloat,
        measuredTextWidth: CGFloat,
        needsInlineMarquee: Bool,
        needsClosedScroll: Bool,
        scrollPhase: LyricScrollPhase,
        marqueeOffset: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.midX = rect.midX
        self.midY = rect.midY
        self.boxWidth = rect.width
        self.boxHeight = rect.height
        self.inlineProgress = inlineProgress
        self.measuredTextWidth = measuredTextWidth
        self.needsInlineMarquee = needsInlineMarquee
        self.needsClosedScroll = needsClosedScroll
        self.scrollPhase = scrollPhase
        self.marqueeOffset = marqueeOffset
        self.content = content()
    }

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(midX, midY),
                AnimatablePair(AnimatablePair(boxWidth, boxHeight), inlineProgress)
            )
        }
        set {
            midX = newValue.first.first
            midY = newValue.first.second
            boxWidth = newValue.second.first.first
            boxHeight = newValue.second.first.second
            inlineProgress = newValue.second.second
        }
    }

    var body: some View {
        let p = max(0.0, min(1.0, inlineProgress))
        let clampedWidth = max(1, boxWidth)
        let clampedHeight = max(1, boxHeight)

        // Smoothly interpolate horizontal alignment between centered (or scrolled closed/bottom edge)
        // and leading (open Home).
        let centeredTextOffsetX = measuredTextWidth > 0
            ? max(0.0, (clampedWidth - measuredTextWidth) / 2.0)
            : 0.0
        let closedTextOffsetX = needsClosedScroll ? marqueeOffset : centeredTextOffsetX
        let inlineTextOffsetX = needsInlineMarquee ? marqueeOffset : 0.0
        let textOffsetX = closedTextOffsetX * (1.0 - p) + inlineTextOffsetX * p
        let closedShadowStrength = Double(1.0 - p)

        let isOverflowScrolling = needsClosedScroll || needsInlineMarquee
        let edgeFade = min(10, clampedWidth * 0.12)
        let leadingFadeWidth: CGFloat = {
            guard isOverflowScrolling else { return 0 }
            switch scrollPhase {
            case .scrolling, .trailingHold:
                return edgeFade
            case .idle, .leadingHold:
                return 0
            }
        }()
        let trailingFadeWidth: CGFloat = {
            guard isOverflowScrolling else { return 0 }
            if needsClosedScroll && scrollPhase == .trailingHold {
                return 0
            }
            return edgeFade
        }()

        content
            .offset(x: textOffsetX)
            .frame(width: clampedWidth, height: clampedHeight, alignment: .leading)
            .clipped()
            .mask {
                if isOverflowScrolling {
                    HStack(spacing: 0) {
                        if leadingFadeWidth > 0 {
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: leadingFadeWidth)
                        }
                        Color.black
                        if trailingFadeWidth > 0 {
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: trailingFadeWidth)
                        }
                    }
                } else {
                    Color.black
                }
            }
            .shadow(
                color: .black.opacity(0.8 * closedShadowStrength),
                radius: 1,
                x: 0,
                y: 1
            )
            .shadow(
                color: .black.opacity(0.5 * closedShadowStrength),
                radius: 3,
                x: 0,
                y: 0
            )
            .position(x: midX, y: midY)
    }
}

struct ClosedNotchLyricView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.mediaColorStyle) private var mediaColorStyle
    @Default(.customMediaColorData) private var customMediaColorData

    private var lyricColor: Color {
        switch mediaColorStyle {
        case .systemDefault:
            return .white
        case .albumArt:
            return Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.85)
        case .custom:
            let custom = MediaColorStyle.resolvedCustomNSColor(from: customMediaColorData)
            return Color(nsColor: custom).ensureMinimumBrightness(factor: 0.85)
        }
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                let elapsed = musicManager.estimatedPlaybackPosition(at: timeline.date)
                let hasSynced = !musicManager.syncedLyrics.isEmpty
                let currentLine = hasSynced ? musicManager.lyricLine(at: elapsed) : plainLyricLine(at: timeline.date)

                Text(currentLine)
                    .font(.subheadline)
                    .foregroundColor(lyricColor)
                    .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 0)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .id(currentLine)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: hasSynced ? 0.3 : 0.5), value: currentLine)
            }
        }
        .padding(.horizontal, 12)
    }

    /// For plain lyrics: split into lines and cycle every ~6 seconds
    private func plainLyricLine(at date: Date) -> String {
        if musicManager.isFetchingLyrics { return "" }
        let plain = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return "" }
        let lines = plain.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }
        let secondsSinceRef = date.timeIntervalSinceReferenceDate
        let index = Int(secondsSinceRef / 6.0) % lines.count
        return lines[index]
    }
}
