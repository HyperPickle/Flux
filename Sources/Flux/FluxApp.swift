import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .iconOnly
    @AppStorage("compactTime") private var compactTime: Bool = false

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            switch menuBarStyle {
            case .iconOnly:
                Image(systemName: "bolt.fill")
            case .percentage:
                Text("\(monitor.batteryLevel)%")
            case .time:
                Text(compactTime ? menuBarTime : monitor.timeRemaining)
            }
        }
        .menuBarExtraStyle(.window)

    }

    private var menuBarTime: String {
        monitor.timeRemaining.components(separatedBy: " ").first ?? monitor.timeRemaining
    }
}
