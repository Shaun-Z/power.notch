//
//  ClosedNotchLyricView.swift
//  powerNotch
//
//

import SwiftUI

/// Shared motion timing constants and curves synchronizing the notch expansion,
/// album-art thumbnail `matchedGeometryEffect`, unified lyric flight, and the
/// post-flight song title & artist reveal so every element arrives on the exact same frame.
enum NotchLyricMotion {
    static let openFlightDuration: Double = 0.38
    static let closeFlightDuration: Double = 0.36

    static let openAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: openFlightDuration)
    static let closeAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: closeFlightDuration)
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

/// Single continuously-mounted lyric view rendered in the fixed `windowSize` overlay of
/// `ContentView`, smoothly translating between the closed-notch strip below the notch and
/// the expanded-notch slot beneath the artist name with zero overshoot.
struct NotchUnifiedLyricOverlay: View {
    @ObservedObject var musicManager = MusicManager.shared

    let anchors: NotchLyricAnchors
    let proxy: GeometryProxy
    let isOpen: Bool
    let showClosedLyrics: Bool
    let showOpenLyrics: Bool
    let isLiquidGlass: Bool
    let gestureProgress: CGFloat

    @State private var settledClosedRect: CGRect = .zero
    @State private var settledOpenRect: CGRect = .zero
    @State private var settledIsOpen: Bool = false
    @State private var isTransitioning: Bool = false
    @State private var transitionResetTask: Task<Void, Never>?
    @State private var wasVisible: Bool = false
    @State private var measuredTextWidth: CGFloat = 0
    @State private var marqueeOffset: CGFloat = 0
    @State private var isScrolling: Bool = false
    @State private var marqueeTask: Task<Void, Never>?

    private let openAnimation = NotchLyricMotion.openAnimation
    private let closeAnimation = NotchLyricMotion.closeAnimation

    private var currentClosedRect: CGRect? {
        guard showClosedLyrics, let anchor = anchors.closed else { return nil }
        let raw = proxy[anchor]
        guard raw.width > 0, raw.height > 0 else { return nil }
        // Inset horizontally in closed mode so text keeps 12pt breathing room on each side.
        return raw.insetBy(dx: 12, dy: 0)
    }

    private var currentOpenRect: CGRect? {
        guard showOpenLyrics, let anchor = anchors.open else { return nil }
        let raw = proxy[anchor]
        guard raw.width > 0, raw.height > 0 else { return nil }
        return raw
    }

    private var activeRect: CGRect? {
        isOpen ? currentOpenRect : currentClosedRect
    }

    private var isInFlight: Bool {
        isTransitioning || (isOpen != settledIsOpen)
    }

    private var isVisible: Bool {
        isOpen ? (showOpenLyrics && musicManager.isPlaying) : showClosedLyrics
    }

    private var closedLyricColor: Color {
        Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.85)
    }

    private var openLyricColor: Color {
        if musicManager.isFetchingLyrics {
            return isLiquidGlass ? Color.white.opacity(0.50) : Color.gray.opacity(0.7)
        }
        return isLiquidGlass ? Color.white.opacity(0.68) : Color.gray
    }

    var body: some View {
        // Lock endpoints to settled rects during open/close transitions (including frame 0)
        // in the static `windowSize` coordinate space so container resizing never drags the
        // target mid-flight and produces overshoot.
        let inFlight = isInFlight
        let startRect: CGRect = {
            if inFlight && settledClosedRect.width > 0 {
                return settledClosedRect
            }
            return currentClosedRect ?? settledClosedRect
        }()
        let endRect: CGRect = {
            if inFlight && settledOpenRect.width > 0 {
                return settledOpenRect
            }
            return currentOpenRect ?? settledOpenRect
        }()
        let hasBothEndpoints = startRect.width > 0 && startRect.height > 0
            && endRect.width > 0 && endRect.height > 0
        let fallbackRect = activeRect ?? (isOpen ? endRect : startRect)
        let effectiveStart = hasBothEndpoints ? startRect : fallbackRect
        let effectiveEnd = hasBothEndpoints ? endRect : fallbackRect
        let targetProgress: CGFloat = (isOpen && endRect.width > 0) ? 1.0 : 0.0
        let shouldAnimateFlight = hasBothEndpoints && (wasVisible || isVisible)

        Group {
            if effectiveStart.width > 0 && effectiveStart.height > 0 {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    let line = currentLyricLine(at: timeline.date)
                    let isPersian = containsPersianCharacters(line)
                    let font: Font = isPersian
                        ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize)
                        : .subheadline
                    let activeContainerWidth = isOpen ? effectiveEnd.width : effectiveStart.width
                    let needsMarquee = isOpen && measuredTextWidth > effectiveEnd.width + 2

                    NotchLyricFlightView(
                        progress: targetProgress,
                        startRect: effectiveStart,
                        endRect: effectiveEnd,
                        measuredTextWidth: measuredTextWidth,
                        needsMarquee: needsMarquee,
                        marqueeOffset: marqueeOffset
                    ) {
                        ZStack(alignment: .leading) {
                            lyricTextView(line: line, font: font, needsMarquee: needsMarquee)
                                .overlay(alignment: .leading) {
                                    if needsMarquee {
                                        lyricTextView(line: line, font: font, needsMarquee: true)
                                            .offset(x: measuredTextWidth + 24)
                                    }
                                }
                        }
                    }
                    .animation(shouldAnimateFlight ? (isOpen ? openAnimation : closeAnimation) : nil, value: targetProgress)
                    .background {
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
                                            updateMeasuredWidth(textGeo.size.width, line: line, containerWidth: activeContainerWidth)
                                        }
                                        .onChange(of: textGeo.size.width) { _, newWidth in
                                            updateMeasuredWidth(newWidth, line: line, containerWidth: activeContainerWidth)
                                        }
                                        .onChange(of: line) { _, newLine in
                                            updateMeasuredWidth(textGeo.size.width, line: newLine, containerWidth: activeContainerWidth)
                                        }
                                        .onChange(of: isOpen) { _, _ in
                                            updateMeasuredWidth(textGeo.size.width, line: line, containerWidth: activeContainerWidth)
                                        }
                                }
                            }
                    }
                }
                .animation(.easeInOut(duration: 0.18)) { view in
                    view.opacity(
                        isVisible
                            ? (gestureProgress != 0 && isOpen ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                            : 0.0
                    )
                }
                .onChange(of: isOpen) { _, _ in
                    beginTransitionWindow()
                }
                .onChange(of: isTransitioning) { _, transitioning in
                    guard !transitioning else { return }
                    settledIsOpen = isOpen
                    if isOpen {
                        if let rect = currentOpenRect {
                            settledOpenRect = rect
                        }
                    } else {
                        if let rect = currentClosedRect {
                            settledClosedRect = rect
                        } else if !showClosedLyrics {
                            settledClosedRect = .zero
                        }
                    }
                }
                .onChange(of: currentClosedRect) { _, newRect in
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
                .onChange(of: currentOpenRect) { _, newRect in
                    if !isInFlight && isOpen, let newRect {
                        settledOpenRect = newRect
                    }
                    wasVisible = isVisible
                }
                .onAppear {
                    settledIsOpen = isOpen
                    if let rect = currentClosedRect {
                        settledClosedRect = rect
                    }
                    if let rect = currentOpenRect {
                        settledOpenRect = rect
                    }
                    wasVisible = isVisible
                }
                .onDisappear {
                    transitionResetTask?.cancel()
                    transitionResetTask = nil
                    marqueeTask?.cancel()
                    marqueeTask = nil
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func beginTransitionWindow() {
        isTransitioning = true
        transitionResetTask?.cancel()
        let settleMs = Int((max(NotchLyricMotion.openFlightDuration, NotchLyricMotion.closeFlightDuration) * 1000).rounded()) + 30
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
            .foregroundColor(isOpen ? openLyricColor : closedLyricColor)
            .animation(.easeOut(duration: 0.24), value: isOpen)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: needsMarquee, vertical: false)
            .id(line)
            .transition(.opacity)
            .animation(.easeInOut(duration: musicManager.syncedLyrics.isEmpty ? 0.5 : 0.28), value: line)
    }

    private func updateMeasuredWidth(_ width: CGFloat, line: String, containerWidth: CGFloat) {
        measuredTextWidth = width
        marqueeTask?.cancel()
        marqueeTask = nil

        let shouldScroll = isOpen && width > containerWidth + 2 && !line.isEmpty
        guard shouldScroll else {
            withAnimation(.easeOut(duration: 0.2)) {
                marqueeOffset = 0
                isScrolling = false
            }
            return
        }

        marqueeOffset = 0
        isScrolling = false
        let travelDistance = width + 24
        let duration = max(3.0, Double(travelDistance / 32.0))

        marqueeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            isScrolling = true
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                marqueeOffset = -travelDistance
            }
        }
    }

    private func currentLyricLine(at date: Date) -> String {
        if musicManager.isFetchingLyrics {
            return isOpen ? "Loading lyrics…" : ""
        }
        if !musicManager.syncedLyrics.isEmpty {
            let elapsed = musicManager.estimatedPlaybackPosition(at: date)
            return musicManager.lyricLine(at: elapsed)
        }
        let plain = plainLyricLine(at: date)
        if plain.isEmpty {
            return isOpen ? "No lyrics found" : ""
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
/// alignment (centered in the closed-notch strip → leading-aligned under the artist name)
/// with zero overshoot.
private struct NotchLyricFlightView<Content: View>: View, Animatable {
    var progress: CGFloat
    let startRect: CGRect
    let endRect: CGRect
    let measuredTextWidth: CGFloat
    let needsMarquee: Bool
    let marqueeOffset: CGFloat
    let content: Content

    init(
        progress: CGFloat,
        startRect: CGRect,
        endRect: CGRect,
        measuredTextWidth: CGFloat,
        needsMarquee: Bool,
        marqueeOffset: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.progress = progress
        self.startRect = startRect
        self.endRect = endRect
        self.measuredTextWidth = measuredTextWidth
        self.needsMarquee = needsMarquee
        self.marqueeOffset = marqueeOffset
        self.content = content()
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = max(0.0, min(1.0, progress))
        let boxWidth = startRect.width + (endRect.width - startRect.width) * p
        let boxHeight = startRect.height + (endRect.height - startRect.height) * p
        let posX = startRect.midX + (endRect.midX - startRect.midX) * p
        let posY = startRect.midY + (endRect.midY - startRect.midY) * p

        // Smoothly interpolate horizontal alignment from centered (closed) to leading (open)
        let closedTextOffsetX = measuredTextWidth > 0
            ? max(0.0, (startRect.width - measuredTextWidth) / 2.0)
            : 0.0
        let openTextOffsetX = needsMarquee ? marqueeOffset : 0.0
        let textOffsetX = closedTextOffsetX * (1.0 - p) + openTextOffsetX * p
        let closedShadowStrength = Double(1.0 - p)

        content
            .offset(x: textOffsetX)
            .frame(width: max(1, boxWidth), height: max(1, boxHeight), alignment: .leading)
            .clipped()
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
            .position(x: posX, y: posY)
    }
}

struct ClosedNotchLyricView: View {
    @ObservedObject var musicManager = MusicManager.shared

    private var lyricColor: Color {
        Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.85)
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
