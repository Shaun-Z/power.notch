//
//  TabSelectionView.swift
//  powerNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
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
    }

    @ViewBuilder
    private var selectedThumb: some View {
        if liquidGlassNotch {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.15)
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
                                    Color.white.opacity(0.42),
                                    Color.white.opacity(0.10)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.65
                        )
                }
        } else {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
