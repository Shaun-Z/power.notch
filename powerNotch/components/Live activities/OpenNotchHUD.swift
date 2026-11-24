//
//  OpenNotchHUD.swift
//  powerNotch
//
//  Created by Alexander on 2024-11-23.
//

import SwiftUI
import Defaults

struct OpenNotchHUD: View {
    @Environment(\.notchGlassInk) private var ink
    @EnvironmentObject var vm: BoringViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Default(.showOpenNotchHUDPercentage) var showPercentage
    @Default(.liquidGlassNotch) var liquidGlassNotch
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Group {
                switch type {
                case .volume:
                    if icon.isEmpty {
                        Image(systemName: SpeakerSymbol(value))
                            .contentTransition(.interpolate)
                    } else {
                        Image(systemName: icon)
                            .contentTransition(.interpolate)
                    }
                case .brightness:
                    Image(systemName: "sun.max.fill")
                        .contentTransition(.symbolEffect)
                case .backlight:
                    Image(systemName: value > 0.5 ? "light.max" : "light.min")
                        .contentTransition(.interpolate)
                case .mic:
                    Image(systemName: value > 0 ? "mic.fill" : "mic.slash.fill")
                        .contentTransition(.interpolate)
                default:
                    EmptyView()
                }
            }
            .font(.system(size: NotchHeaderMetrics.iconSize, weight: .semibold))
            .foregroundStyle(ink.primary(0.92))
            .frame(width: 18, alignment: .center)
            
            // Slider or Status Text
            if type != .mic {
                DraggableProgressBar(value: $value, onChange: { newVal in
                     updateSystemValue(newVal)
                })
                .frame(width: showPercentage ? 65 : 108) // Fixed width for consistency
            } else {
                Text(value > 0 ? "Unmuted" : "Muted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.primary(0.92))
                    .fixedSize()
            }
            
            // Percentage Text
            if type != .mic && showPercentage {
                Text("\(Int(value * 100))%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.secondary(0.76))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NotchHeaderMetrics.controlHeight)
        .notchHeaderGlassSurface(
            isLiquidGlass: liquidGlassNotch,
            isActive: false,
            isHovering: false,
            isInteractive: false
        )
    }
    
    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0: return "speaker.slash.fill"
            case 0...0.33: return "speaker.wave.1.fill"
            case 0.33...0.66: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
        }
    }
    
    func updateSystemValue(_ newVal: CGFloat) {
        switch type {
        case .volume:
            VolumeManager.shared.setAbsolute(Float32(newVal))
        case .brightness:
            BrightnessManager.shared.setAbsolute(value: Float32(newVal))
        default:
            break
        }
    }
}

#Preview {
    OpenNotchHUD(type: .constant(.volume), value: .constant(0.5), icon: .constant(""))
        .environmentObject(BoringViewModel())
        .padding()
        .background(Color.gray)
}
