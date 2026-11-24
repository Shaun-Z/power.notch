//
//  BoringHeader.swift
//  powerNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

// MARK: - Unified Liquid Glass Header Styling

enum NotchHeaderMetrics {
    static let controlHeight: CGFloat = 28
    static let iconSize: CGFloat = 12.5
    static let controlSpacing: CGFloat = 6
    static let tabInnerPadding: CGFloat = 2
}

struct NotchHeaderPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

private struct NotchHeaderGlassSurfaceModifier: ViewModifier {
    @Environment(\.notchGlassInk) private var ink
    let isLiquidGlass: Bool
    let isActive: Bool
    let isHovering: Bool
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLiquidGlass {
            if #available(macOS 26.0, *) {
                let tintOpacity: Double = isActive ? 0.24 : (isHovering ? 0.14 : 0.06)
                let baseGlass = Glass.clear.tint(ink.surface(tintOpacity))
                let glass = isInteractive ? baseGlass.interactive() : baseGlass
                content
                    .glassEffect(glass, in: Capsule())
            } else {
                content
                    .background {
                        Capsule()
                            .fill(ink.surface(isActive ? 0.22 : (isHovering ? 0.14 : 0.09)))
                            .overlay {
                                Capsule()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                ink.border(isActive ? 0.42 : (isHovering ? 0.30 : 0.20)),
                                                ink.border(isActive ? 0.16 : 0.07)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 0.75
                                    )
                            }
                    }
            }
        } else {
            content
                .background {
                    Capsule()
                        .fill(ink.surface(isActive ? 0.20 : (isHovering ? 0.13 : 0.08)))
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    ink.border(isActive ? 0.24 : (isHovering ? 0.16 : 0.10)),
                                    lineWidth: 0.5
                                )
                        }
                }
        }
    }
}

extension View {
    func notchHeaderGlassSurface(
        isLiquidGlass: Bool,
        isActive: Bool = false,
        isHovering: Bool = false,
        isInteractive: Bool = true
    ) -> some View {
        modifier(
            NotchHeaderGlassSurfaceModifier(
                isLiquidGlass: isLiquidGlass,
                isActive: isActive,
                isHovering: isHovering,
                isInteractive: isInteractive
            )
        )
    }
}

struct NotchHeaderGlassGroup<Content: View>: View {
    let isLiquidGlass: Bool
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isLiquidGlass {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) {
                    content()
                }
            } else {
                content()
            }
        } else {
            content()
        }
    }
}

struct NotchHeaderIconButton: View {
    @Environment(\.notchGlassInk) private var ink
    let systemName: String
    var isActive: Bool = false
    let isLiquidGlass: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: NotchHeaderMetrics.iconSize, weight: .semibold))
                .foregroundStyle(ink.primary(isActive ? 1.0 : (isHovering ? 0.96 : 0.84)))
                .frame(
                    width: NotchHeaderMetrics.controlHeight,
                    height: NotchHeaderMetrics.controlHeight
                )
                .contentShape(Capsule())
                .notchHeaderGlassSurface(
                    isLiquidGlass: isLiquidGlass,
                    isActive: isActive,
                    isHovering: isHovering,
                    isInteractive: true
                )
        }
        .buttonStyle(NotchHeaderPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Header View

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @Default(.liquidGlassNotch) var liquidGlassNotch
    @Default(.boringShelf) var boringShelf
    @Default(.enableAIUsageNotchTab) var enableAIUsageNotchTab

    private var shouldShowTabPicker: Bool {
        let shelfVisible = (!tvm.isEmpty || coordinator.alwaysShowTabs) && boringShelf
        return shelfVisible || enableAIUsageNotchTab
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchHeaderMetrics.controlSpacing) {
                if shouldShowTabPicker {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .zIndex(2)

            if vm.notchState == .open {
                let showSolidNotchSpacer = !liquidGlassNotch && (NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0)
                Rectangle()
                    .fill(showSolidNotchSpacer ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            NotchHeaderGlassGroup(
                isLiquidGlass: liquidGlassNotch,
                spacing: NotchHeaderMetrics.controlSpacing
            ) {
                HStack(spacing: NotchHeaderMetrics.controlSpacing) {
                    if vm.notchState == .open {
                        if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                            OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                                .transition(.scale(scale: 0.88).combined(with: .opacity))
                        } else {
                            if Defaults[.showMirror] {
                                NotchHeaderIconButton(
                                    systemName: "web.camera.fill",
                                    isActive: vm.isCameraExpanded,
                                    isLiquidGlass: liquidGlassNotch
                                ) {
                                    vm.toggleCameraPreview()
                                }
                            }
                            if Defaults[.settingsIconInNotch] {
                                NotchHeaderIconButton(
                                    systemName: "gearshape.fill",
                                    isActive: false,
                                    isLiquidGlass: liquidGlassNotch
                                ) {
                                    DispatchQueue.main.async {
                                        SettingsWindowController.shared.showWindow()
                                    }
                                }
                            }
                            if Defaults[.showBatteryIndicator] {
                                BoringBatteryView(
                                    batteryWidth: 23,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    maxCapacity: batteryModel.maxCapacity,
                                    timeToFullCharge: batteryModel.timeToFullCharge,
                                    isForNotification: false
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .zIndex(2)
        }
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
