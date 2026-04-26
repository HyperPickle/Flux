import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var monitor = BatteryMonitor()
    
    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            Image(systemName: "bolt.fill")
                .foregroundColor(menuBarColor)
        }
        .menuBarExtraStyle(.window)
    }
    
    private var menuBarColor: Color {
        // Dynamic color based on battery drain / level
        if monitor.isCharging {
            return .green
        } else if monitor.batteryLevel <= 20 || monitor.isLowPowerMode {
            return .yellow
        } else if monitor.totalEnergyImpact > 100 {
            // High drain
            return .orange
        } else {
            return .primary
        }
    }
}
