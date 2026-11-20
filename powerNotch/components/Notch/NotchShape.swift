//
//  NotchShape.swift
//  powerNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    private var liquidCurve: Bool

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        liquidCurve: Bool = false
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.liquidCurve = liquidCurve
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(
                topCornerRadius,
                bottomCornerRadius
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Self.contourPath(
            in: rect,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve
        )
        path.closeSubpath()
        return path
    }

    /// Traces the hanging notch contour from top-left around the bottom to top-right
    /// without closing across the top screen bezel edge.
    static func contourPath(
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        liquidCurve: Bool
    ) -> Path {
        var path = Path()
        let maxTopRadius = max(0, min(topCornerRadius, rect.width / 4, rect.height / 2))
        let maxBottomRadius = max(0, min(bottomCornerRadius, (rect.width - 2 * maxTopRadius) / 2, rect.height - maxTopRadius))

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        if liquidCurve {
            // Smooth continuous cubic Bezier curves for a hanging water-droplet meniscus & silhouette
            let topHandle: CGFloat = 0.68
            let bottomHandle: CGFloat = 0.64

            // Top-left concave liquid meniscus
            path.addCurve(
                to: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.minY + maxTopRadius
                ),
                control1: CGPoint(
                    x: rect.minX + maxTopRadius * topHandle,
                    y: rect.minY
                ),
                control2: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.minY + maxTopRadius * (1 - topHandle)
                )
            )

            // Left vertical wall
            path.addLine(
                to: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.maxY - maxBottomRadius
                )
            )

            // Bottom-left continuous superellipse-style corner
            path.addCurve(
                to: CGPoint(
                    x: rect.minX + maxTopRadius + maxBottomRadius,
                    y: rect.maxY
                ),
                control1: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.maxY - maxBottomRadius * (1 - bottomHandle)
                ),
                control2: CGPoint(
                    x: rect.minX + maxTopRadius + maxBottomRadius * (1 - bottomHandle),
                    y: rect.maxY
                )
            )

            // Bottom edge
            path.addLine(
                to: CGPoint(
                    x: rect.maxX - maxTopRadius - maxBottomRadius,
                    y: rect.maxY
                )
            )

            // Bottom-right continuous superellipse-style corner
            path.addCurve(
                to: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.maxY - maxBottomRadius
                ),
                control1: CGPoint(
                    x: rect.maxX - maxTopRadius - maxBottomRadius * (1 - bottomHandle),
                    y: rect.maxY
                ),
                control2: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.maxY - maxBottomRadius * (1 - bottomHandle)
                )
            )

            // Right vertical wall
            path.addLine(
                to: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.minY + maxTopRadius
                )
            )

            // Top-right concave liquid meniscus
            path.addCurve(
                to: CGPoint(
                    x: rect.maxX,
                    y: rect.minY
                ),
                control1: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.minY + maxTopRadius * (1 - topHandle)
                ),
                control2: CGPoint(
                    x: rect.maxX - maxTopRadius * topHandle,
                    y: rect.minY
                )
            )
        } else {
            path.addQuadCurve(
                to: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.minY + maxTopRadius
                ),
                control: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.minY
                )
            )

            path.addLine(
                to: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.maxY - maxBottomRadius
                )
            )

            path.addQuadCurve(
                to: CGPoint(
                    x: rect.minX + maxTopRadius + maxBottomRadius,
                    y: rect.maxY
                ),
                control: CGPoint(
                    x: rect.minX + maxTopRadius,
                    y: rect.maxY
                )
            )

            path.addLine(
                to: CGPoint(
                    x: rect.maxX - maxTopRadius - maxBottomRadius,
                    y: rect.maxY
                )
            )

            path.addQuadCurve(
                to: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.maxY - maxBottomRadius
                ),
                control: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.maxY
                )
            )

            path.addLine(
                to: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.minY + maxTopRadius
                )
            )

            path.addQuadCurve(
                to: CGPoint(
                    x: rect.maxX,
                    y: rect.minY
                ),
                control: CGPoint(
                    x: rect.maxX - maxTopRadius,
                    y: rect.minY
                )
            )
        }

        return path
    }
}

/// Open path tracing only the hanging outer silhouette of the notch (omitting the flat top bezel edge)
/// so Liquid Glass specular rim lighting never draws an artificial line across the top screen edge.
struct NotchRimShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat
    private var liquidCurve: Bool

    init(
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        liquidCurve: Bool = true
    ) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.liquidCurve = liquidCurve
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        NotchShape.contourPath(
            in: rect,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: liquidCurve
        )
    }
}

/// Liquid Glass background for the expanded notch:
/// renders native macOS 26+ SwiftUI `.glassEffect(.regular, in: NotchShape(...))` unclipped so
/// WindowServer produces genuine system-matched transparency, optical refraction, and specular
/// depth along both the concave top meniscus shoulders and rounded bottom corners, topped with
/// a smooth Gaussian-feathered pure-black hardware-notch transition driven by the screen's
/// physical notch dimensions.
struct NotchGlassBackground: View {
    let isOpen: Bool
    let useLiquidGlass: Bool
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    var physicalNotchSize: CGSize? = nil
    var showRim: Bool = true

    private var activeNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: useLiquidGlass
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if useLiquidGlass {
                // 1. Native Liquid Glass following the exact animated NotchShape silhouette
                //    (concave top-left/top-right ears + rounded bottom corners).
                //    NOT wrapped in outer SwiftUI .clipShape/.shadow so WindowServer renders
                //    full optical edge refraction and system-matched transparency.
                nativeGlassBackdrop

                // 2. Extended, ultra-smooth black hardware-notch transition driven directly by the
                //    physical display's hardware notch dimensions (omitted on non-notched screens).
                //    Kept at full opacity (1.0) at all times and clipped by activeNotchShape so
                //    the inner pure-black core NEVER fades out or jumps during close before the
                //    outer glass edge retracts.
                if let physicalNotch = physicalNotchSize, physicalNotch.height > 0 {
                    Color.clear
                        .overlay(alignment: .top) {
                            hardwareNotchDarkTransition(
                                in: openNotchSize,
                                notchWidth: physicalNotch.width,
                                notchHeight: physicalNotch.height
                            )
                        }
                        .clipShape(activeNotchShape)
                        .allowsHitTesting(false)
                }

                // 3. Solid pure-black closed notch veil covering the full dynamic closed width
                //    (including music album art / spectrum wings). Dissolves smoothly on open and
                //    ramps smoothly back to solid black as the outer edge retracts on close.
                Color.black
                    .clipShape(activeNotchShape)
                    .animation(isOpen ? .easeOut(duration: 0.30) : .easeInOut(duration: 0.34)) { view in
                        view.opacity(isOpen ? 0.0 : 1.0)
                    }
                    .allowsHitTesting(false)
            } else {
                // Classic solid black mode when Liquid Glass is disabled
                Color.black
                    .clipShape(activeNotchShape)
            }
        }
        .overlay {
            if showRim && useLiquidGlass {
                NotchLiquidGlassRim(
                    isOpen: isOpen,
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
            }
        }
    }

    @ViewBuilder
    private var nativeGlassBackdrop: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: activeNotchShape)
                .animation(isOpen ? .easeOut(duration: 0.14) : .easeIn(duration: 0.42)) { view in
                    view.opacity(isOpen ? 1.0 : 0.0)
                }
        } else {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(activeNotchShape)
                .animation(isOpen ? .easeOut(duration: 0.14) : .easeIn(duration: 0.42)) { view in
                    view.opacity(isOpen ? 1.0 : 0.0)
                }
        }
    }

    @ViewBuilder
    private func hardwareNotchDarkTransition(
        in size: CGSize,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> some View {
        let usableWidth = max(0, size.width - topCornerRadius * 2)
        let clampedWidth = min(notchWidth, usableWidth)
        let clampedHeight = min(notchHeight, size.height * 0.45)

        ZStack(alignment: .top) {
            // Wide velvety elliptical ambient falloff spanning the full glass card
            EllipticalGradient(
                stops: [
                    .init(color: Color.black.opacity(0.80), location: 0.0),
                    .init(color: Color.black.opacity(0.72), location: 0.14),
                    .init(color: Color.black.opacity(0.58), location: 0.28),
                    .init(color: Color.black.opacity(0.40), location: 0.44),
                    .init(color: Color.black.opacity(0.22), location: 0.58),
                    .init(color: Color.black.opacity(0.09), location: 0.72),
                    .init(color: Color.black.opacity(0.025), location: 0.85),
                    .init(color: Color.black.opacity(0.0), location: 0.98)
                ],
                center: .top,
                startRadiusFraction: 0.0,
                endRadiusFraction: 0.86
            )

            // Broad mid-range Gaussian veil extending smoothly beneath and around the physical notch
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: max(18, clampedHeight * 0.75),
                bottomTrailingRadius: max(18, clampedHeight * 0.75),
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black.opacity(0.78))
            .frame(width: clampedWidth + clampedHeight * 1.8, height: clampedHeight * 2.15)
            .blur(radius: max(18, clampedHeight * 0.74))
            .offset(y: -clampedHeight * 0.32)

            // Pure-black core extending slightly PAST the model's exact physical hardware notch bottom
            // so the physical bezel boundary dissolves completely with zero hard step.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: max(12, clampedHeight * 0.48),
                bottomTrailingRadius: max(12, clampedHeight * 0.48),
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: clampedWidth + clampedHeight * 0.65, height: clampedHeight * 1.48)
            .blur(radius: max(10, clampedHeight * 0.38))
            .offset(y: -4)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// Subtle directional specular edge accent tracing the full hanging `NotchRimShape` contour
/// (concave top-left/top-right meniscus shoulders, vertical walls, and continuous rounded bottom
/// corners). Rides directly on `mainLayout`'s animated frame & corner radii so there is never
/// a secondary scale animation or delayed pop.
struct NotchLiquidGlassRim: View {
    let isOpen: Bool
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat

    private var rimShape: NotchRimShape {
        NotchRimShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: true
        )
    }

    private var clipNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            liquidCurve: true
        )
    }

    var body: some View {
        ZStack {
            // Soft internal glass-thickness caustic bevel along the curved corners
            rimShape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.05), location: 0.0),
                            .init(color: Color.white.opacity(0.16), location: 0.45),
                            .init(color: Color.white.opacity(0.30), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 2.0)
                .blendMode(.plusLighter)
                .clipShape(clipNotchShape)

            // Crisp directional diagonal specular reflection catching light on curved shoulders & corners
            rimShape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.55), location: 0.0),
                            .init(color: Color.white.opacity(0.24), location: 0.18),
                            .init(color: Color.white.opacity(0.08), location: 0.46),
                            .init(color: Color.white.opacity(0.14), location: 0.68),
                            .init(color: Color.white.opacity(0.60), location: 0.90),
                            .init(color: Color.white.opacity(0.80), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )
                .blendMode(.plusLighter)

            // Opposite-diagonal soft corner catchlight (bottom-left & upper-right glass curves)
            rimShape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.46), location: 0.0),
                            .init(color: Color.white.opacity(0.06), location: 0.28),
                            .init(color: Color.white.opacity(0.0), location: 0.55),
                            .init(color: Color.white.opacity(0.24), location: 0.85),
                            .init(color: Color.white.opacity(0.42), location: 1.0)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round)
                )
                .blendMode(.plusLighter)
        }
        // Taper the top 5pt softly so the concave shoulder highlight dissolves cleanly into the top bezel
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white, location: 0.03),
                    .init(color: .white, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(isOpen ? .easeIn(duration: 0.30) : .easeOut(duration: 0.24)) { view in
            view.opacity(isOpen ? 1.0 : 0.0)
        }
        .allowsHitTesting(false)
    }
}

#Preview("Liquid Glass Expanded Notch") {
    ZStack(alignment: .top) {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.28, blue: 0.42),
                    Color(red: 0.40, green: 0.44, blue: 0.56),
                    Color(red: 0.62, green: 0.54, blue: 0.48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 32) {
                ForEach(0..<16, id: \.self) { _ in
                    Rectangle().fill(.white.opacity(0.30)).frame(width: 8)
                }
            }
        }

        NotchGlassBackground(
            isOpen: true,
            useLiquidGlass: true,
            topCornerRadius: 22,
            bottomCornerRadius: 34,
            physicalNotchSize: CGSize(width: 185, height: 38)
        )
        .frame(width: 640, height: 226)
    }
    .preferredColorScheme(.dark)
    .frame(width: 720, height: 280)
}

