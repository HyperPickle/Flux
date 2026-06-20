import AppKit
import SwiftUI

@main
struct FluxApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .iconOnly
    @AppStorage("compactTime") private var compactTime: Bool = false
    @AppStorage("compactBattery") private var compactBattery: Bool = false

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
                .preferredColorScheme(appAppearance.preferredColorScheme)
                .onAppear {
                    applyAppearance(appAppearance)
                }
                .onChange(of: appAppearance) { _, newAppearance in
                    applyAppearance(newAppearance)
                }
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

    private func applyAppearance(_ appearance: AppAppearance) {
        let application = NSApplication.shared
        switch appearance {
        case .system:
            application.appearance = nil
        case .light:
            application.appearance = NSAppearance(named: .aqua)
        case .dark:
            application.appearance = NSAppearance(named: .darkAqua)
        }
        // Reset the cached icon so the AppIcon asset resolves its matching
        // light or dark appearance after the application override changes.
        application.applicationIconImage = nil
    }
}
