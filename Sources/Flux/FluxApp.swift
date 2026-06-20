import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .iconOnly
    @AppStorage("compactTime") private var compactTime: Bool = false
    @AppStorage("compactBattery") private var compactBattery: Bool = false

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            switch menuBarStyle {
            case .iconOnly:
                Image(systemName: "bolt.fill")
            case .battery:
                if compactBattery {
                    Text("\(monitor.batteryLevel)%")
                } else {
                    Text("\(monitor.batteryLevel)% battery")
                }
            case .time:
                Text(compactTime ? menuBarTime : monitor.timeRemaining)
            case .batteryAndTime:
                let battery = compactBattery
                    ? "\(monitor.batteryLevel)%"
                    : "\(monitor.batteryLevel)% battery"
                let time = compactTime ? menuBarTime : monitor.timeRemaining
                Text("\(battery) • \(time)")
            }
        }
        .menuBarExtraStyle(.window)

    }

    private var menuBarTime: String {
        monitor.timeRemaining.components(separatedBy: " ").first ?? monitor.timeRemaining
    }
}
