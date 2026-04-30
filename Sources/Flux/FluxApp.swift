import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var monitor = BatteryMonitor()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            Image(systemName: monitor.isCharging ? "battery.100.bolt" : "battery.100", variableValue: Double(monitor.batteryLevel) / 100.0)
                .foregroundColor(menuBarColor)
        }
        .menuBarExtraStyle(.window)
    }
    
    private var menuBarColor: Color {
        if monitor.isLowPowerMode {
            return .yellow
        } else if monitor.batteryLevel <= 20 {
            return .red
        } else {
            return .primary
        }
    }
}
