//
//  TabSelectionView.swift
//  powerNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    var id: NotchViews { view }
    let label: String
    let icon: String
    let view: NotchViews
}

struct TabSelectionView: View {
    @Environment(\.notchGlassInk) private var ink
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var tvm = ShelfStateViewModel.shared
    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Default(.boringShelf) private var boringShelf
    @Default(.enableAIUsageNotchTab) private var enableAIUsageNotchTab
    @Namespace private var animation

    private var availableTabs: [TabModel] {
        var result: [TabModel] = [
            TabModel(label: "Home", icon: "house.fill", view: .home)
        ]
        if (!tvm.isEmpty || coordinator.alwaysShowTabs) && boringShelf {
            result.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
        }
        if enableAIUsageNotchTab {
            result.append(TabModel(label: "AI Usage", icon: "chart.bar.xaxis", view: .aiUsage))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(availableTabs) { tab in
                let isSelected = coordinator.currentView == tab.view
                TabButton(
                    label: tab.label,
                    icon: tab.icon,
                    selected: isSelected,
                    isLiquidGlass: liquidGlassNotch
                ) {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        coordinator.currentView = tab.view
                    }
                }
                .background {
                    if isSelected {
                        selectedThumb
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    }
                }
            }
        }
        .padding(NotchHeaderMetrics.tabInnerPadding)
        .frame(height: NotchHeaderMetrics.controlHeight)
        .notchHeaderGlassSurface(
            isLiquidGlass: liquidGlassNotch,
            isActive: false,
            isHovering: false,
            isInteractive: false
        )
        .onChange(of: enableAIUsageNotchTab) { _, enabled in
            if !enabled && coordinator.currentView == .aiUsage {
                coordinator.currentView = .home
            }
        }
    }

    @ViewBuilder
    private var selectedThumb: some View {
        if liquidGlassNotch {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            ink.surface(0.28),
                            ink.surface(0.15)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    ink.border(0.42),
                                    ink.border(0.10)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.65
                        )
                }
        } else {
            Capsule()
                .fill(ink.surface(0.18))
                .overlay {
                    Capsule()
                        .strokeBorder(ink.border(0.16), lineWidth: 0.5)
                }
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
