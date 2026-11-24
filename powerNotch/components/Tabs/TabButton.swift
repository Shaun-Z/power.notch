//
//  TabButton.swift
//  powerNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    @Environment(\.notchGlassInk) private var ink
    let label: String
    let icon: String
    let selected: Bool
    var isLiquidGlass: Bool = true
    let onClick: () -> Void

    @State private var isHovering: Bool = false

    private var innerHeight: CGFloat {
        NotchHeaderMetrics.controlHeight - NotchHeaderMetrics.tabInnerPadding * 2
    }

    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .font(.system(size: NotchHeaderMetrics.iconSize, weight: .semibold))
                .foregroundStyle(
                    selected
                        ? ink.primary(1.0)
                        : (isHovering ? ink.primary(0.84) : ink.secondary(0.56))
                )
                .padding(.horizontal, 12)
                .frame(height: innerHeight)
                .background {
                    if !selected && isHovering {
                        Capsule()
                            .fill(ink.surface(isLiquidGlass ? 0.09 : 0.07))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(NotchHeaderPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(label)
    }
}

#Preview {
    TabButton(label: "Home", icon: "house.fill", selected: true) {
        print("Tapped")
    }
}
