import SwiftUI
import Defaults

/// A view that displays the battery status with an icon and charging indicator.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var icon: String = "battery.0"

    /// Determines the icon to display when charging.
    var iconStatus: String {
        if isCharging {
            return "bolt"
        }
        else if isPluggedIn {
            return "plug"
        }
        else {
            return ""
        }
    }

    /// Determines the color of the battery based on its status.
    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else if isCharging || isPluggedIn || levelBattery == 100 {
            return .green
        } else {
            return .white
        }
    }

    var body: some View {
        let clampedLevel = max(0, min(100, CGFloat(levelBattery)))
        let maxFillWidth = max(0, batteryWidth * 0.77)
        let fillWidth = (clampedLevel / 100) * maxFillWidth
        let fillHeight = max(5, batteryWidth * 0.305)
        let leadingInset = max(1.75, batteryWidth * 0.075)
        let cornerRadius = max(1.6, batteryWidth * 0.08)
        let statusIconSize = min(16, batteryWidth * 0.58)

        ZStack(alignment: .leading) {
            Image(systemName: icon)
                .resizable()
                .fontWeight(isForNotification ? .thin : .regular)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white.opacity(isForNotification ? 0.5 : 0.65))
                .frame(width: batteryWidth + 1)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(batteryColor)
                .frame(width: fillWidth, height: fillHeight)
                .padding(.leading, leadingInset)
        }
        .overlay(alignment: .center) {
            if iconStatus != "" && (isForNotification || Defaults[.showPowerStatusIcons]) {
                Image(iconStatus)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(width: statusIconSize, height: statusIconSize)
            }
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// A view that displays detailed battery information and settings.
struct BatteryMenuView: View {
    
    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float
    var timeToFullCharge: Int
    var isInLowPowerMode: Bool
    var onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Battery Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Max Capacity: \(Int(maxCapacity))%")
                    .font(.subheadline)
                    .fontWeight(.regular)
                if isInLowPowerMode {
                    Label("Low Power Mode", systemImage: "bolt.circle")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isPluggedIn {
                    Label("Plugged In", systemImage: "powerplug.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if timeToFullCharge > 0 {
                    Label("Time to Full Charge: \(timeToFullCharge) min", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && isPluggedIn && levelBattery >= 80 {
                    Label("Charging on Hold: Desktop Mode", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                    
            }
            .padding(.vertical, 8)

            Divider().background(Color.white)

            Button(action: openBatteryPreferences) {
                Label("Battery Settings", systemImage: "gearshape")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(width: 280)
        .foregroundColor(.white)
    }

    private func openBatteryPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            openURL(url)
            onDismiss()
        }
    }
}

/// A view that displays the battery status and allows interaction to show detailed information.
struct BoringBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    @State var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil

    @Default(.liquidGlassNotch) private var liquidGlassNotch
    @Default(.showBatteryPercentage) private var showBatteryPercentage
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        Group {
            if isForNotification {
                Button(action: {
                    withAnimation {
                        showPopupMenu.toggle()
                    }
                }) {
                    HStack {
                        if showBatteryPercentage {
                            Text("\(Int32(levelBattery))%")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        BatteryView(
                            levelBattery: levelBattery,
                            isPluggedIn: isPluggedIn,
                            isCharging: isCharging,
                            isInLowPowerMode: isInLowPowerMode,
                            batteryWidth: batteryWidth,
                            isForNotification: isForNotification
                        )
                    }
                }
                .buttonStyle(ScaleButtonStyle())
            } else {
                Button(action: {
                    withAnimation {
                        showPopupMenu.toggle()
                    }
                }) {
                    HStack(spacing: 5) {
                        if showBatteryPercentage {
                            Text("\(Int32(levelBattery))%")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(
                                    Color.white.opacity(
                                        showPopupMenu ? 1.0 : (isHoveringButton ? 0.96 : 0.88)
                                    )
                                )
                        }
                        BatteryView(
                            levelBattery: levelBattery,
                            isPluggedIn: isPluggedIn,
                            isCharging: isCharging,
                            isInLowPowerMode: isInLowPowerMode,
                            batteryWidth: batteryWidth,
                            isForNotification: isForNotification
                        )
                    }
                    .padding(.horizontal, showBatteryPercentage ? 9 : 8)
                    .frame(height: NotchHeaderMetrics.controlHeight)
                    .contentShape(Capsule())
                    .notchHeaderGlassSurface(
                        isLiquidGlass: liquidGlassNotch,
                        isActive: showPopupMenu,
                        isHovering: isHoveringButton,
                        isInteractive: true
                    )
                }
                .buttonStyle(NotchHeaderPressStyle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.16)) {
                        isHoveringButton = hovering
                    }
                    if hovering {
                        hideTask?.cancel()
                        hideTask = nil
                    } else if showPopupMenu {
                        scheduleHideIfNeeded()
                    }
                }
            }
        }
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                isInLowPowerMode: isInLowPowerMode,
                onDismiss: { 
                    showPopupMenu = false
                }
            )
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    hideTask?.cancel()
                    hideTask = nil
                } else {
                    scheduleHideIfNeeded()
                }
            }
        }
        .onChange(of: showPopupMenu) {
            vm.isBatteryPopoverActive = showPopupMenu
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showPopupMenu = false } }
        }
    }
}

#Preview {
    BoringBatteryView(
        batteryWidth: 23,
        isCharging: false,
        isInLowPowerMode: false,
        isPluggedIn: true,
        levelBattery: 80,
        maxCapacity: 100,
        timeToFullCharge: 10,
        isForNotification: false
    )
    .environmentObject(BoringViewModel())
    .frame(width: 200, height: 200)
}
