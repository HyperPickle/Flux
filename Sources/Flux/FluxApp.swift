import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .iconOnly

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundColor(menuBarColor)
                
                if menuBarStyle == .iconPercentage {
                    Text("\(monitor.batteryLevel)%")
                } else if menuBarStyle == .iconTime {
                    Text(monitor.timeRemaining)
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    private var menuBarColor: Color {
        if monitor.batteryLevel <= 20 {
            return .red
        } else {
            return .primary
        }
    }
}
