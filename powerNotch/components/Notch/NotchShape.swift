//
//  NotchShape.swift
//  powerNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI
import Defaults

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    private var liquidCurve: Bool
    private var islandMorph: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        liquidCurve: Bool = false,
        islandMorph: CGFloat = 0
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.liquidCurve = liquidCurve
        self.islandMorph = islandMorph
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get {
            .init(
                topCornerRadius,
                .init(bottomCornerRadius, islandMorph)
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second.first
            islandMorph = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Self.contourPath(
            in: rect,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            closeTopEdge: true
        )
        path.closeSubpath()
        return path
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private static func lerpPoint(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }

    /// Cubic Bezier handle factor for convex Dynamic Island corners:
    /// Uses the exact circular-arc handle (0.55228475) so the outer Dynamic Island arc
    /// (R_outer = R_inner + d) is a mathematically exact parallel offset curve to inner
    /// Capsule/Circle controls and concentric rounded cards with zero 45° diagonal bulge.
    private static func islandCornerHandle(radius: CGFloat, halfHeight: CGFloat) -> CGFloat {
        0.55228475
    }

    /// Traces the outer silhouette, smoothly morphing between:
    /// - `islandMorph == 0`: hanging notch with concave top meniscus ears & rounded bottom corners
    /// - `islandMorph == 1`: Dynamic Island continuous rounded capsule / superellipse card
    static func contourPath(
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        liquidCurve: Bool,
        islandMorph: CGFloat = 0,
        closeTopEdge: Bool = false
    ) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let m = min(1, max(0, islandMorph))

        // Hanging-notch clamped radii (m == 0)
        let rTN = max(0, min(topCornerRadius, rect.width / 4, rect.height / 2))
        let rBN = max(0, min(bottomCornerRadius, (rect.width - 2 * rTN) / 2, rect.height - rTN))

        // Dynamic-Island clamped radii (m == 1)
        let rTI = max(0, min(topCornerRadius, rect.width / 2, rect.height / 2))
        let rBI = max(0, min(bottomCornerRadius, rect.width / 2, rect.height - rTI))

        // Concave top meniscus ear handle (hanging notch) vs exact concentric circular-arc handle
        // (0.55228475) for convex bottom corners so both Hanging Notch and Dynamic Island modes
        // form exact parallel offset curves to inner R=14pt cards with zero 45° bulge.
        let topH: CGFloat = liquidCurve ? 0.68 : (2.0 / 3.0)
        let botH: CGFloat = 0.55228475

        let halfH = rect.height / 2
        let kT = islandCornerHandle(radius: rTI, halfHeight: halfH)
        let kB = islandCornerHandle(radius: rBI, halfHeight: halfH)

        // Segment 1: Top-left corner
        let tl0 = lerpPoint(
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX + rTI, y: rect.minY),
            m
        )
        let tlC1 = lerpPoint(
            CGPoint(x: rect.minX + rTN * topH, y: rect.minY),
            CGPoint(x: rect.minX + rTI * (1 - kT), y: rect.minY),
            m
        )
        let tlC2 = lerpPoint(
            CGPoint(x: rect.minX + rTN, y: rect.minY + rTN * (1 - topH)),
            CGPoint(x: rect.minX, y: rect.minY + rTI * (1 - kT)),
            m
        )
        let tl3 = lerpPoint(
            CGPoint(x: rect.minX + rTN, y: rect.minY + rTN),
            CGPoint(x: rect.minX, y: rect.minY + rTI),
            m
        )

        // Segment 3: Bottom-left corner
        let bl0 = lerpPoint(
            CGPoint(x: rect.minX + rTN, y: rect.maxY - rBN),
            CGPoint(x: rect.minX, y: rect.maxY - rBI),
            m
        )
        let blC1 = lerpPoint(
            CGPoint(x: rect.minX + rTN, y: rect.maxY - rBN * (1 - botH)),
            CGPoint(x: rect.minX, y: rect.maxY - rBI * (1 - kB)),
            m
        )
        let blC2 = lerpPoint(
            CGPoint(x: rect.minX + rTN + rBN * (1 - botH), y: rect.maxY),
            CGPoint(x: rect.minX + rBI * (1 - kB), y: rect.maxY),
            m
        )
        let bl3 = lerpPoint(
            CGPoint(x: rect.minX + rTN + rBN, y: rect.maxY),
            CGPoint(x: rect.minX + rBI, y: rect.maxY),
            m
        )

        // Segment 5: Bottom-right corner
        let br0 = lerpPoint(
            CGPoint(x: rect.maxX - rTN - rBN, y: rect.maxY),
            CGPoint(x: rect.maxX - rBI, y: rect.maxY),
            m
        )
        let brC1 = lerpPoint(
            CGPoint(x: rect.maxX - rTN - rBN * (1 - botH), y: rect.maxY),
            CGPoint(x: rect.maxX - rBI * (1 - kB), y: rect.maxY),
            m
        )
        let brC2 = lerpPoint(
            CGPoint(x: rect.maxX - rTN, y: rect.maxY - rBN * (1 - botH)),
            CGPoint(x: rect.maxX, y: rect.maxY - rBI * (1 - kB)),
            m
        )
        let br3 = lerpPoint(
            CGPoint(x: rect.maxX - rTN, y: rect.maxY - rBN),
            CGPoint(x: rect.maxX, y: rect.maxY - rBI),
            m
        )

        // Segment 7: Top-right corner
        let tr0 = lerpPoint(
            CGPoint(x: rect.maxX - rTN, y: rect.minY + rTN),
            CGPoint(x: rect.maxX, y: rect.minY + rTI),
            m
        )
        let trC1 = lerpPoint(
            CGPoint(x: rect.maxX - rTN, y: rect.minY + rTN * (1 - topH)),
            CGPoint(x: rect.maxX, y: rect.minY + rTI * (1 - kT)),
            m
        )
        let trC2 = lerpPoint(
            CGPoint(x: rect.maxX - rTN * topH, y: rect.minY),
            CGPoint(x: rect.maxX - rTI * (1 - kT), y: rect.minY),
            m
        )
        let tr3 = lerpPoint(
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX - rTI, y: rect.minY),
            m
        )

        path.move(to: tl0)
        path.addCurve(to: tl3, control1: tlC1, control2: tlC2)
        path.addLine(to: bl0)
        path.addCurve(to: bl3, control1: blC1, control2: blC2)
        path.addLine(to: br0)
        path.addCurve(to: br3, control1: brC1, control2: brC2)
        path.addLine(to: tr0)
        path.addCurve(to: tr3, control1: trC1, control2: trC2)

        if closeTopEdge {
            path.addLine(to: tl0)
        }

        return path
    }
}

/// Path tracing the hanging/island outer silhouette. Omits the flat top bezel edge by default
/// (for physical-notch and hanging-notch modes), or closes the full 360° perimeter when
/// `includeTopEdge` is true (floating Dynamic Island on non-notched displays).
struct NotchRimShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    private var liquidCurve: Bool
    private var islandMorph: CGFloat
    private var canvasBleed: CGFloat
    /// Positive values expand the stroke contour outward (outside the black/glass bezel so
    /// the physical hardware notch never occludes the specular edge); negative values inset inward.
    private var edgeOffset: CGFloat
    private var includeTopEdge: Bool

    init(
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        liquidCurve: Bool = true,
        islandMorph: CGFloat = 0,
        canvasBleed: CGFloat = 0,
        edgeOffset: CGFloat = 0,
        includeTopEdge: Bool = false
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.liquidCurve = liquidCurve
        self.islandMorph = islandMorph
        self.canvasBleed = canvasBleed
        self.edgeOffset = edgeOffset
        self.includeTopEdge = includeTopEdge
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(topCornerRadius, bottomCornerRadius), .init(islandMorph, edgeOffset)) }
        set {
            topCornerRadius = newValue.first.first
            bottomCornerRadius = newValue.first.second
            islandMorph = newValue.second.first
            edgeOffset = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let m = min(1, max(0, islandMorph))
        // On an unpadded interior canvas (canvasBleed == 0), nudge Dynamic Island strokes slightly
        // inward to keep full stroke weight inside bounds; on an expanded exterior canvas, apply
        // `edgeOffset` directly from the exact outer bezel boundary.
        let effectiveOffset = canvasBleed > 0 ? edgeOffset : (edgeOffset - 0.4 * m)
        let horizontalInset = canvasBleed - effectiveOffset
        let topInset = includeTopEdge ? (canvasBleed - effectiveOffset) : 0
        let bottomInset = canvasBleed - effectiveOffset
        let drawRect = CGRect(
            x: rect.minX + horizontalInset,
            y: rect.minY + topInset,
            width: max(0, rect.width - 2 * horizontalInset),
            height: max(0, rect.height - topInset - bottomInset)
        )
        // Exact concentric parallel offset:
        // - Bottom arcs keep identical center point with radius = bottomCornerRadius + effectiveOffset.
        // - Top corners keep topCornerRadius for outward expansion (preserving both hanging ear wall
        //   alignment and Dynamic Island flush-top fit) and shrink by effectiveOffset when inset.
        let adjustedTopRadius = max(0, topCornerRadius + (effectiveOffset < 0 ? effectiveOffset : 0))
        let adjustedBottomRadius = max(0, bottomCornerRadius + effectiveOffset)
        var path = NotchShape.contourPath(
            in: drawRect,
            topCornerRadius: adjustedTopRadius,
            bottomCornerRadius: adjustedBottomRadius,
            liquidCurve: liquidCurve,
            islandMorph: m,
            closeTopEdge: includeTopEdge
        )
        if includeTopEdge {
            path.closeSubpath()
        }
        return path
    }
}

/// Even-odd exterior clip shape covering the expanded halo/rim canvas OUTSIDE `NotchShape`,
/// ensuring outward glass highlights & music aura passes sit purely outside the bezel with
/// zero inward spill into the glass interior or behind the physical hardware notch.
struct NotchExteriorClipShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    private var liquidCurve: Bool
    private var islandMorph: CGFloat
    private var canvasBleed: CGFloat
    private var holeInset: CGFloat

    init(
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        liquidCurve: Bool = true,
        islandMorph: CGFloat = 0,
        canvasBleed: CGFloat = 0,
        holeInset: CGFloat = 0.15
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.liquidCurve = liquidCurve
        self.islandMorph = islandMorph
        self.canvasBleed = canvasBleed
        self.holeInset = holeInset
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(topCornerRadius, .init(bottomCornerRadius, islandMorph)) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second.first
            islandMorph = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        path.addRect(rect)

        let m = min(1, max(0, islandMorph))
        let notchRect = CGRect(
            x: rect.minX + canvasBleed + holeInset,
            y: rect.minY,
            width: max(0, rect.width - 2 * (canvasBleed + holeInset)),
            height: max(0, rect.height - (canvasBleed + holeInset))
        )
        var hole = NotchShape.contourPath(
            in: notchRect,
            topCornerRadius: max(0, topCornerRadius - holeInset),
            bottomCornerRadius: max(0, bottomCornerRadius - holeInset),
            liquidCurve: liquidCurve,
            islandMorph: m,
            closeTopEdge: true
        )
        hole.closeSubpath()
        path.addPath(hole)
        return path
    }
}

/// AppKit's native rounded glass surface for Dynamic Island mode.
/// Keep the effect view unmasked so AppKit controls its own glass edge rendering.
@available(macOS 26.0, *)
private struct NativeIslandGlassBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat
    let useClearGlass: Bool

    private var resolvedTintColor: NSColor? {
        useClearGlass ? nil : .black.withAlphaComponent(LiquidGlassAppearance.tintOpacity)
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .clear
        view.tintColor = resolvedTintColor
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        if nsView.tintColor != resolvedTintColor {
            nsView.tintColor = resolvedTintColor
        }
        if context.transaction.animation == nil {
            nsView.cornerRadius = cornerRadius
        } else {
            context.animate {
                nsView.animator().cornerRadius = cornerRadius
            }
        }
    }
}

/// Measures the closed content, but gets every intermediate size from the surface's single driver.
private struct NotchSurfaceLayout: Layout {
    var progress: CGFloat
    let isOpen: Bool
    let openSize: CGSize
    let fallbackClosedSize: CGSize

    struct Cache {
        var closedSize: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(closedSize: fallbackClosedSize)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Retain the last closed measurement when the expanded content replaces it.
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if !isOpen, let content = subviews.first {
            let measured = content.sizeThatFits(.unspecified)
            if measured.width.isFinite, measured.height.isFinite {
                cache.closedSize = measured
            }
        }
        let p = min(1, max(0, progress))
        return CGSize(
            width: max(0, cache.closedSize.width + (openSize.width - cache.closedSize.width) * p),
            height: max(0, cache.closedSize.height + (openSize.height - cache.closedSize.height) * p)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for content in subviews {
            content.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// One animation vector owns layout, content clipping, glass, ink, and the exterior rim.
struct NotchCardSurface: AnimatableModifier {
    var openProgress: CGFloat
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var islandMorph: CGFloat
    let isOpen: Bool
    let openSize: CGSize
    let fallbackClosedSize: CGSize
    let useLiquidGlass: Bool
    let useNativeIslandBackdrop: Bool
    let physicalNotchSize: CGSize?
    let isVisible: Bool
    let showBaseGlassRim: Bool
    let showFluidMusicRim: Bool
    let themeColor: NSColor

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { .init(openProgress, .init(topCornerRadius, .init(bottomCornerRadius, islandMorph))) }
        set {
            openProgress = min(1, max(0, newValue.first))
            topCornerRadius = max(0, newValue.second.first)
            bottomCornerRadius = max(0, newValue.second.second.first)
            islandMorph = min(1, max(0, newValue.second.second.second))
        }
    }

    func body(content: Content) -> some View {
        let contour = NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: useLiquidGlass,
            islandMorph: islandMorph
        )

        // These decorations consume already-interpolated geometry. The original content keeps
        // its own transitions/matched geometry; none of the surface layers starts another animation.
        content.transaction { $0.animation = nil } body: { inner in
            NotchSurfaceLayout(
                progress: openProgress,
                isOpen: isOpen,
                openSize: openSize,
                fallbackClosedSize: fallbackClosedSize
            ) {
                inner
            }
            .clipShape(contour)
            .background {
                NotchGlassBackground(
                    isOpen: isOpen,
                    useLiquidGlass: useLiquidGlass,
                    openProgress: openProgress,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    islandMorph: islandMorph,
                    useNativeIslandBackdrop: useNativeIslandBackdrop,
                    physicalNotchSize: physicalNotchSize,
                    isVisible: isVisible,
                    showRim: false
                )
            }
            .overlay {
                if showBaseGlassRim || showFluidMusicRim {
                    NotchLiquidGlassRim(
                        isOpen: isOpen,
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius,
                        liquidCurve: useLiquidGlass,
                        islandMorph: islandMorph,
                        showBaseGlassRim: showBaseGlassRim,
                        showFluidMusicRim: showFluidMusicRim,
                        outwardMusicGlow: (physicalNotchSize?.height ?? 0) > 0,
                        themeColor: themeColor
                    )
                }
            }
        }
    }
}

/// Shared geometry keeps the visible ink and the software-cursor mask aligned.
struct HardwareNotchInkGeometry {
    let physicalNotchSize: CGSize
    let surfaceSize: CGSize

    var notchSize: CGSize {
        CGSize(
            width: max(0, min(physicalNotchSize.width, surfaceSize.width)),
            height: max(0, min(physicalNotchSize.height, surfaceSize.height))
        )
    }

    var extentSize: CGSize {
        CGSize(
            width: max(0, surfaceSize.width),
            height: min(surfaceSize.height, physicalNotchSize.height * 3)
        )
    }
}

/// A dense contact edge spreads into a broad ink bloom around the hardware notch.
/// The full surface width lets the bloom reach both wings in the extended state.
struct HardwareNotchInkTransition: View, Animatable {
    let physicalNotchSize: CGSize
    let surfaceSize: CGSize
    var topCornerRadius: CGFloat = 0
    var bottomCornerRadius: CGFloat = 0
    var islandMorph: CGFloat = 0

    // Only the enclosing silhouette animates. The ink's dimensions and density stay fixed.
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(topCornerRadius, .init(bottomCornerRadius, islandMorph)) }
        set {
            topCornerRadius = max(0, newValue.first)
            bottomCornerRadius = max(0, newValue.second.first)
            islandMorph = min(1, max(0, newValue.second.second))
        }
    }

    var body: some View {
        let width = max(0, physicalNotchSize.width)
        let height = max(0, physicalNotchSize.height)

        ZStack(alignment: .top) {
            // A compact diffuse halo surrounds a denser, horizontal pill of ink.
            Capsule()
                .fill(.black.opacity(0.28))
                .frame(width: width + height * 3.2, height: height * 2.5)
                .blur(radius: height * 0.32)
                .offset(y: -height * 0.85)

            Capsule()
                .fill(.black)
                .frame(width: width + height * 2.4, height: height * 2)
                .blur(radius: height * 0.16)
                .offset(y: -height * 0.65)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
        .clipShape(NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: true,
            islandMorph: islandMorph
        ))
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
    }
}

/// Native dark transparent Liquid Glass for the notch / Dynamic Island silhouette.
/// A localized ink bloom blends the physical notch into the glass. Side and bottom
/// refraction remain visible when top reflections are hidden.
struct NotchGlassBackground: View {
    @Default(.liquidGlassOpacity) private var liquidGlassOpacity
    @Default(.developerClearLiquidGlass) private var clearLiquidGlass

    let isOpen: Bool
    let useLiquidGlass: Bool
    var openProgress: CGFloat? = nil
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    var islandMorph: CGFloat = 0
    // Stable across open/close: only use AppKit when both endpoints remain rounded islands.
    var useNativeIslandBackdrop: Bool = false
    var physicalNotchSize: CGSize? = nil
    var isVisible: Bool = true
    var showFluidMusicRim: Bool = false
    var themeColor: NSColor = .white
    var showRim: Bool = true

    private var suppressTopReflection: Bool {
        if clearLiquidGlass && (physicalNotchSize?.height ?? 0) == 0 {
            return false
        }
        return islandMorph < 1 || (physicalNotchSize?.height ?? 0) > 0
    }

    private var activeNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: useLiquidGlass,
            islandMorph: islandMorph
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if useLiquidGlass {
                nativeGlassBackdrop
                    .mask {
                        // Keep the native side/bottom refraction, but discard its top specular band.
                        GeometryReader { geometry in
                            Path { path in
                                let topInset: CGFloat = suppressTopReflection ? 2 : -16
                                path.addRect(CGRect(
                                    x: -16,
                                    y: topInset,
                                    width: geometry.size.width + 32,
                                    height: geometry.size.height + 16 - topInset
                                ))
                            }
                            .fill(.white)
                        }
                    }
                    .overlay(alignment: .top) {
                        if suppressTopReflection {
                            Color.black
                                .frame(height: 2)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .clipShape(activeNotchShape)
                        }
                    }

                if let physicalNotch = physicalNotchSize, physicalNotch.height > 0 {
                    // The surface itself morphs between the card and closed notch silhouettes.
                    // Its closed color stays solid black beneath the static ink.
                    activeNotchShape
                        .fill(.black)
                        .opacity(1 - (openProgress ?? (isOpen ? 1 : 0)))

                    GeometryReader { geometry in
                        HardwareNotchInkTransition(
                            physicalNotchSize: physicalNotch,
                            surfaceSize: geometry.size,
                            topCornerRadius: topCornerRadius,
                            bottomCornerRadius: bottomCornerRadius,
                            islandMorph: islandMorph
                        )
                    }
                        .opacity(isVisible ? 1.0 : 0.0)
                        .allowsHitTesting(false)
                }
            } else {
                // Classic solid black mode when Liquid Glass is disabled
                Color.black
                    .clipShape(activeNotchShape)
            }
        }
        .overlay {
            if showRim && (useLiquidGlass || showFluidMusicRim) {
                NotchLiquidGlassRim(
                    isOpen: isOpen,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    liquidCurve: useLiquidGlass,
                    islandMorph: islandMorph,
                    showBaseGlassRim: useLiquidGlass && isVisible && !showFluidMusicRim,
                    showFluidMusicRim: showFluidMusicRim && isVisible,
                    outwardMusicGlow: (physicalNotchSize?.height ?? 0) > 0,
                    themeColor: themeColor
                )
            }
        }
    }

    @ViewBuilder
    private var nativeGlassBackdrop: some View {
        if #available(macOS 26.0, *) {
            Group {
                if useNativeIslandBackdrop {
                    NativeIslandGlassBackdrop(
                        cornerRadius: topCornerRadius,
                        useClearGlass: clearLiquidGlass
                    )
                } else {
                    Color.clear
                        .glassEffect(
                            clearLiquidGlass
                                ? .clear
                                : .clear.tint(.black.opacity(LiquidGlassAppearance.tintOpacity)),
                            in: activeNotchShape
                        )
                }
            }
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
        } else {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay {
                    if !clearLiquidGlass {
                        Color.black.opacity(LiquidGlassAppearance.tintOpacity)
                    }
                }
                .clipShape(activeNotchShape)
                .opacity(isVisible ? min(1, max(0, liquidGlassOpacity)) : 0)
        }
    }


}

/// Liquid Glass edge highlight tracing the full hanging `NotchRimShape` contour
/// (concave top-left/top-right meniscus shoulders, vertical walls, and continuous rounded bottom
/// corners).
/// - When idle/paused: renders the classic white directional Liquid Glass specular reflection.
/// - While media is playing: crossfades into a music-themed fluid spectrum rim driven by
///   multi-band harmonic light waves.
///
/// IMPORTANT: `rimShape` and `clipNotchShape` intentionally live OUTSIDE `TimelineView` and use
/// only scoped `.animation(_:body:)` on `.opacity(...)` so they inherit 100% of `mainLayout`'s
/// exact `NotchLyricMotion` animation curve with zero staggered/double rim scaling.
struct NotchLiquidGlassRim: View {
    let isOpen: Bool
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    var liquidCurve: Bool = true
    var islandMorph: CGFloat = 0
    var showBaseGlassRim: Bool = true
    var showFluidMusicRim: Bool = false
    /// When true (displays with a physical hardware notch), the music fluid halo diffuses
    /// strictly outward so the hardware notch bezel never occludes it. When false (non-notched
    /// displays), preserves the classic inward caustic glass-thickness rim glow.
    var outwardMusicGlow: Bool = false
    var themeColor: NSColor = .white

    private let haloBleed: CGFloat = 18
    private let glassRimBleed: CGFloat = 6

    /// True for the floating Dynamic Island on non-notched displays, where the top edge floats
    /// below the screen bezel and the full 360° perimeter carries glass reflection & music glow.
    private var includeTopEdge: Bool {
        !outwardMusicGlow && islandMorph >= 0.5
    }

    private var rimShape: NotchRimShape {
        NotchRimShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            includeTopEdge: includeTopEdge
        )
    }

    /// Fine exterior specular rim contour for notched displays, sitting cleanly outside the black
    /// bezel (+0.45pt closed / +0.35pt open) so the physical hardware notch never occludes it.
    private var outwardGlassRimShape: NotchRimShape {
        NotchRimShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            canvasBleed: glassRimBleed,
            edgeOffset: isOpen ? 0.35 : 0.45
        )
    }

    private var glassExteriorClipShape: NotchExteriorClipShape {
        NotchExteriorClipShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            canvasBleed: glassRimBleed,
            holeInset: 0.05
        )
    }

    private var outwardRimShape: NotchRimShape {
        NotchRimShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            canvasBleed: haloBleed
        )
    }

    private var outwardMusicEdgeRimShape: NotchRimShape {
        NotchRimShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            canvasBleed: haloBleed,
            edgeOffset: isOpen ? 0.35 : 0.45
        )
    }

    private var exteriorClipShape: NotchExteriorClipShape {
        NotchExteriorClipShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph,
            canvasBleed: haloBleed
        )
    }

    private var clipNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve,
            islandMorph: islandMorph
        )
    }

    @ViewBuilder
    private var topEdgeFadeMask: some View {
        if includeTopEdge {
            // Floating Dynamic Island on non-notched displays: illuminate the entire 360° perimeter
            // including the top edge with zero top-edge fade suppression.
            Color.white
        } else {
            GeometryReader { geometry in
                // Only feather the immediate top screen-bezel contact line (y = 0) so the flat top
                // edge never shows a horizontal specular bar or clipped blur cap, while preserving
                // full Liquid Glass reflection and music glow along the upper-left/upper-right
                // corners and vertical side walls.
                let height = max(1, geometry.size.height)
                let clearStop = min(0.02, 1.0 / height)
                let fadeDistance: CGFloat = isOpen ? 6.0 : 3.0
                let fullStop = max(clearStop + 0.01, min(0.14, fadeDistance / height))
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: clearStop),
                        .init(color: .white, location: fullStop),
                        .init(color: .white, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private struct ThemeRimPalette {
        let primary: Color
        let harmonic: Color
        let highlight: Color
        let deepGlow: Color

        init(nsColor: NSColor) {
            let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

            let isNearMonochrome = s < 0.08
            let primarySat: CGFloat = isNearMonochrome ? s : min(1.0, max(s * 1.15, 0.58))
            let primaryBri: CGFloat = max(b, 0.90)

            let harmonicHue = (h + 0.075).truncatingRemainder(dividingBy: 1.0)
            let harmonicSat: CGFloat = isNearMonochrome ? s : min(1.0, max(primarySat * 0.92, 0.48))
            let harmonicBri: CGFloat = max(b, 0.94)

            let highlightSat: CGFloat = isNearMonochrome ? 0.0 : min(primarySat * 0.34, 0.30)
            let deepSat: CGFloat = isNearMonochrome ? s : min(1.0, max(primarySat * 1.10, 0.72))

            self.primary = Color(hue: Double(h), saturation: Double(primarySat), brightness: Double(primaryBri))
            self.harmonic = Color(hue: Double(harmonicHue), saturation: Double(harmonicSat), brightness: Double(harmonicBri))
            self.highlight = Color(hue: Double(h), saturation: Double(highlightSat), brightness: 1.0)
            self.deepGlow = Color(hue: Double(h), saturation: Double(deepSat), brightness: max(Double(b), 0.78))
        }
    }

    var body: some View {
        let palette = ThemeRimPalette(nsColor: themeColor)

        ZStack {
            // MARK: A. Refined Liquid Glass Specular Rim (widget-matched hairline, shown when idle)
            Group {
                if outwardMusicGlow {
                    // Notched displays: render the delicate glass hairline on the exterior canvas
                    // strictly outside the black/glass bezel so the physical hardware notch never
                    // occludes it (even in fullscreen when closed height == physical notch height).
                    baseGlassRimLayers(shape: outwardGlassRimShape, clipExterior: true)
                        .mask { topEdgeFadeMask }
                        .padding(
                            EdgeInsets(
                                top: 0,
                                leading: -glassRimBleed,
                                bottom: -glassRimBleed,
                                trailing: -glassRimBleed
                            )
                        )
                } else {
                    baseGlassRimLayers(shape: rimShape, clipExterior: false)
                        .mask { topEdgeFadeMask }
                }
            }
            .animation(.easeInOut(duration: 0.32)) { view in
                view.opacity(showBaseGlassRim ? (isOpen ? 0.82 : 0.90) : 0.0)
            }

            // MARK: B. Music-Themed Fluid Spectrum Rim (shown only while media is playing)
            ZStack {
                if outwardMusicGlow {
                    // Notched displays: outward-only ambient halo, near-rim bloom, and fine outer
                    // specular hairline rendered on an expanded (W + 2*haloBleed, H + haloBleed)
                    // exterior canvas so light diffuses purely outward and is never occluded by
                    // the physical hardware notch.
                    ZStack {
                        // 1. Wide soft outward ambient aura (normal alpha blend stays vivid on both
                        //    light and dark wallpapers without washing out)
                        fluidSpectrumLightField(palette: palette, isCausticPass: true, canvasBleed: haloBleed)
                            .mask {
                                outwardRimShape
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(
                                            lineWidth: isOpen ? 11.0 : 9.0,
                                            lineCap: .round,
                                            lineJoin: .round
                                        )
                                    )
                                    .blur(radius: isOpen ? 7.0 : 5.5)
                            }
                            .clipShape(exteriorClipShape, style: FillStyle(eoFill: true))
                            .opacity(isOpen ? 0.62 : 0.74)

                        // 2. Energetic luminous outward bloom hugging the outer bezel edge
                        fluidSpectrumLightField(palette: palette, isCausticPass: false, canvasBleed: haloBleed)
                            .mask {
                                outwardRimShape
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(
                                            lineWidth: isOpen ? 5.0 : 4.2,
                                            lineCap: .round,
                                            lineJoin: .round
                                        )
                                    )
                                    .blur(radius: isOpen ? 2.8 : 2.2)
                            }
                            .clipShape(exteriorClipShape, style: FillStyle(eoFill: true))
                            .opacity(isOpen ? 0.78 : 0.86)
                            .blendMode(.plusLighter)

                        // 3. Delicate continuous exterior specular hairline keeping the contour crisp
                        fluidSpectrumLightField(palette: palette, isCausticPass: false, canvasBleed: haloBleed)
                            .mask {
                                outwardMusicEdgeRimShape
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(
                                            lineWidth: isOpen ? 0.90 : 0.80,
                                            lineCap: .round,
                                            lineJoin: .round
                                        )
                                    )
                            }
                            .clipShape(exteriorClipShape, style: FillStyle(eoFill: true))
                            .blendMode(.plusLighter)
                    }
                    .mask { topEdgeFadeMask }
                    .padding(
                        EdgeInsets(
                            top: 0,
                            leading: -haloBleed,
                            bottom: -haloBleed,
                            trailing: -haloBleed
                        )
                    )
                } else {
                    // Non-notched displays: preserve the classic inward caustic glass-thickness rim glow
                    ZStack {
                        // 1. Internal caustic glass-thickness glow masked by the synchronously animated rimShape
                        fluidSpectrumLightField(palette: palette, isCausticPass: true, canvasBleed: 0)
                            .mask {
                                rimShape
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round)
                                    )
                                    .blur(radius: 2.3)
                            }
                            .clipShape(clipNotchShape)
                            .blendMode(.plusLighter)

                        // 2. Soft radiant fluid spectrum shimmer riding along the glass edge
                        let radiantShimmer = fluidSpectrumLightField(palette: palette, isCausticPass: false, canvasBleed: 0)
                            .mask {
                                rimShape
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                                    )
                                    .blur(radius: 1.5)
                            }
                            .opacity(0.62)
                            .blendMode(.plusLighter)

                        if includeTopEdge {
                            radiantShimmer.clipShape(clipNotchShape)
                        } else {
                            radiantShimmer
                        }

                        // 3. Crisp continuous specular edge keeping the Liquid Glass contour razor-sharp
                        let specularEdge = fluidSpectrumLightField(palette: palette, isCausticPass: false, canvasBleed: 0)
                            .mask {
                                rimShape
                                    .stroke(
                                        Color.white,
                                        style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
                                    )
                            }
                            .blendMode(.plusLighter)

                        if includeTopEdge {
                            specularEdge.clipShape(clipNotchShape)
                        } else {
                            specularEdge
                        }
                    }
                    .mask { topEdgeFadeMask }
                }
            }
            .animation(.easeInOut(duration: 0.32)) { view in
                view.opacity(showFluidMusicRim ? (isOpen ? 1.0 : (outwardMusicGlow ? 0.94 : 0.92)) : 0.0)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func baseGlassRimLayers(
        shape: NotchRimShape,
        clipExterior: Bool
    ) -> some View {
        let rimContent = ZStack {
            // 1. Whisper-fine optical glass edge refraction (replaces heavy inner caustic band)
            let sheen = shape
                .stroke(
                    LinearGradient(
                        stops: includeTopEdge
                            ? [
                                .init(color: Color.white.opacity(0.15), location: 0.0),
                                .init(color: Color.white.opacity(0.08), location: 0.50),
                                .init(color: Color.white.opacity(0.16), location: 1.0)
                            ]
                            : [
                                .init(color: Color.white.opacity(0.03), location: 0.0),
                                .init(color: Color.white.opacity(0.09), location: 0.50),
                                .init(color: Color.white.opacity(0.16), location: 1.0)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(
                        lineWidth: isOpen ? 1.35 : 1.15,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .blur(radius: isOpen ? 1.0 : 0.85)
                .blendMode(.plusLighter)

            if clipExterior {
                sheen
            } else {
                sheen.clipShape(clipNotchShape)
            }

            // 2. Subtle neutral crystal hairline so the glass rim stays naturally legible on both
            //    bright and dark desktop wallpapers, matching macOS 26 desktop widget glass
            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.22), location: 0.0),
                            .init(color: Color.white.opacity(0.10), location: 0.35),
                            .init(color: Color.white.opacity(0.10), location: 0.65),
                            .init(color: Color.white.opacity(0.24), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 0.55, lineCap: .round, lineJoin: .round)
                )

            // 3. Delicate overhead diagonal specular glint strongest along the curved corners
            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.48), location: 0.0),
                            .init(color: Color.white.opacity(0.20), location: 0.16),
                            .init(color: Color.white.opacity(0.06), location: 0.45),
                            .init(color: Color.white.opacity(0.12), location: 0.72),
                            .init(color: Color.white.opacity(0.42), location: 0.90),
                            .init(color: Color.white.opacity(0.56), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: isOpen ? 0.72 : 0.65,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .blendMode(.plusLighter)

            // 4. Soft cross-diagonal bounce catchlight on opposite curved corners
            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.30), location: 0.0),
                            .init(color: Color.white.opacity(0.05), location: 0.24),
                            .init(color: Color.white.opacity(0.0), location: 0.55),
                            .init(color: Color.white.opacity(0.16), location: 0.84),
                            .init(color: Color.white.opacity(0.28), location: 1.0)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    style: StrokeStyle(lineWidth: 0.52, lineCap: .round, lineJoin: .round)
                )
                .blendMode(.plusLighter)
        }

        if clipExterior {
            rimContent.clipShape(glassExteriorClipShape, style: FillStyle(eoFill: true))
        } else if includeTopEdge {
            rimContent.clipShape(clipNotchShape)
        } else {
            rimContent
        }
    }

    @ViewBuilder
    private func fluidSpectrumLightField(
        palette: ThemeRimPalette,
        isCausticPass: Bool,
        canvasBleed: CGFloat = 0
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !showFluidMusicRim)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            // Multi-band harmonic spectrum synthesis (organic bass swell + flowing wing waves + treble crest)
            let phrasing = 0.72 + 0.28 * sin(t * 0.65)
            let bassRaw = 0.5 + 0.5 * (0.62 * sin(t * 3.7) + 0.38 * sin(t * 5.9 + 1.1))
            let bass = max(0.18, min(1.0, bassRaw * phrasing))
            let lowMid = 0.5 + 0.5 * (0.58 * sin(t * 4.9 + 0.7) + 0.42 * cos(t * 7.3 + 2.1))
            let mid = 0.5 + 0.5 * (0.55 * sin(t * 6.3 + 2.4) + 0.45 * sin(t * 9.1 + 0.4))
            let highMid = 0.5 + 0.5 * (0.58 * cos(t * 5.4 + 1.8) + 0.42 * sin(t * 8.6 + 3.0))
            let treble = 0.5 + 0.5 * (0.50 * sin(t * 8.1 + 0.9) + 0.50 * cos(t * 11.7 + 1.5))

            let drift = 0.22 * sin(t * 1.15)
            let bassX = 0.50 + 0.08 * sin(t * 1.4)
            let leftX = 0.14 + 0.14 * sin(t * 1.85 + 0.6)
            let leftY = 0.72 + 0.22 * cos(t * 1.55)
            let rightX = 0.86 + 0.14 * sin(t * 2.05 + 2.8)
            let rightY = 0.72 + 0.22 * cos(t * 1.65 + 1.1)
            let trebleX = 0.50 + 0.38 * sin(t * 1.35 + 1.2)

            GeometryReader { geo in
                let maxDim = max(geo.size.width, geo.size.height, 1)
                let notchBottomY = max(0.45, (geo.size.height - canvasBleed) / max(geo.size.height, 1))

                ZStack {
                    // Flowing themed specular base gradient
                    LinearGradient(
                        stops: [
                            .init(color: (isCausticPass ? palette.deepGlow : palette.highlight).opacity(isCausticPass ? 0.34 : 0.54), location: 0.0),
                            .init(color: palette.primary.opacity(isCausticPass ? 0.58 : 0.42), location: max(0.08, 0.25 + drift * 0.6)),
                            .init(color: palette.harmonic.opacity(isCausticPass ? 0.72 : 0.56), location: max(0.15, min(0.85, 0.50 - drift * 0.8))),
                            .init(color: palette.primary.opacity(isCausticPass ? 0.58 : 0.44), location: min(0.92, 0.75 + drift * 0.6)),
                            .init(color: (isCausticPass ? palette.deepGlow : palette.highlight).opacity(isCausticPass ? 0.34 : 0.68), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(isCausticPass ? (0.54 + bass * 0.38) : (0.70 + mid * 0.24))

                    // Center-bottom bass fluid pulse riding along the bottom bezel edge
                    RadialGradient(
                        colors: [
                            palette.primary.opacity(0.48 + bass * 0.50),
                            palette.primary.opacity(0.0)
                        ],
                        center: UnitPoint(x: bassX, y: notchBottomY),
                        startRadius: 0,
                        endRadius: maxDim * (0.20 + bass * 0.22)
                    )

                    // Left-wing low-mid fluid wave
                    RadialGradient(
                        colors: [
                            palette.harmonic.opacity(0.38 + lowMid * 0.55),
                            palette.harmonic.opacity(0.0)
                        ],
                        center: UnitPoint(x: leftX, y: leftY * notchBottomY),
                        startRadius: 0,
                        endRadius: maxDim * (0.16 + lowMid * 0.16)
                    )

                    // Right-wing high-mid fluid wave
                    RadialGradient(
                        colors: [
                            palette.harmonic.opacity(0.38 + highMid * 0.55),
                            palette.harmonic.opacity(0.0)
                        ],
                        center: UnitPoint(x: rightX, y: rightY * notchBottomY),
                        startRadius: 0,
                        endRadius: maxDim * (0.16 + highMid * 0.16)
                    )

                    // Treble glass-white specular crest gliding along the bottom arc
                    RadialGradient(
                        colors: [
                            palette.highlight.opacity(0.42 + treble * 0.54),
                            palette.highlight.opacity(0.0)
                        ],
                        center: UnitPoint(x: trebleX, y: notchBottomY * 0.96),
                        startRadius: 0,
                        endRadius: maxDim * (0.12 + treble * 0.12)
                    )

                    if includeTopEdge {
                        // Top-edge harmonic fluid pulse & counter-gliding specular crest so the
                        // entire 360° perimeter of the floating Dynamic Island glows evenly.
                        let topPulseX = 0.50 - 0.12 * cos(t * 1.55 + 0.5)
                        let topCrestX = 0.50 - 0.36 * sin(t * 1.25 + 0.9)

                        RadialGradient(
                            colors: [
                                palette.primary.opacity(0.44 + mid * 0.48),
                                palette.primary.opacity(0.0)
                            ],
                            center: UnitPoint(x: topPulseX, y: 0.0),
                            startRadius: 0,
                            endRadius: maxDim * (0.18 + mid * 0.20)
                        )

                        RadialGradient(
                            colors: [
                                palette.highlight.opacity(0.38 + treble * 0.50),
                                palette.highlight.opacity(0.0)
                            ],
                            center: UnitPoint(x: topCrestX, y: 0.04),
                            startRadius: 0,
                            endRadius: maxDim * (0.12 + treble * 0.12)
                        )
                    }
                }
            }
        }
    }
}

#Preview("Liquid Glass Extended Notch") {
    HardwareNotchGlassPreview(isOpen: false)
}

#Preview("Liquid Glass Expanded Notch") {
    HardwareNotchGlassPreview(isOpen: true)
}

#Preview("Notched Island Closed") {
    HardwareNotchGlassPreview(isOpen: false, islandMorph: 1)
}

#Preview("Notched Island Expanded") {
    HardwareNotchGlassPreview(isOpen: true, islandMorph: 1)
}

private struct HardwareNotchGlassPreview: View {
    let isOpen: Bool
    var islandMorph: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.28, blue: 0.42),
                    Color(red: 0.40, green: 0.44, blue: 0.56),
                    Color(red: 0.62, green: 0.54, blue: 0.48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if isOpen {
                HStack(spacing: 32) {
                    ForEach(0..<16, id: \.self) { _ in
                        Rectangle().fill(.white.opacity(0.30)).frame(width: 8)
                    }
                }
            }

            NotchGlassBackground(
                isOpen: isOpen,
                useLiquidGlass: true,
                topCornerRadius: islandMorph == 1 ? (isOpen ? 34 : 16) : (isOpen ? 22 : 6),
                bottomCornerRadius: isOpen ? 34 : (islandMorph == 1 ? 16 : 14),
                islandMorph: islandMorph,
                physicalNotchSize: CGSize(width: 185, height: isOpen ? 38 : 32),
                showFluidMusicRim: isOpen,
                themeColor: .systemOrange
            )
            .frame(width: isOpen ? 640 : 315, height: isOpen ? 226 : 32)
        }
        .preferredColorScheme(.dark)
        .frame(width: isOpen ? 720 : 360, height: isOpen ? 280 : 80)
    }
}
