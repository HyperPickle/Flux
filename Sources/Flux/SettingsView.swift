import SwiftUI
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconOnly = "Icon Only"
    case iconPercentage = "Icon + Percentage"
    case iconTime = "Icon + Time Remaining"
    var id: Self { self }
}

enum UpdateIntervalSetting: Int, CaseIterable, Identifiable {
    case fast = 2
    case normal = 5
    case slow = 10
    var id: Self { self }
    var label: String {
        switch self {
        case .fast: return "Fast (2s)"
        case .normal: return "Normal (5s)"
        case .slow: return "Slow (10s)"
        }
    }
}

enum GraphHistoryZoom: Int, CaseIterable, Identifiable {
    case oneHour = 1
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24
    var id: Self { self }
    var label: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .sixHours: return "6 Hours"
        case .twelveHours: return "12 Hours"
        case .twentyFourHours: return "24 Hours"
        }
    }
}

struct SettingsView: View {
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .iconOnly
    @AppStorage("updateInterval") private var updateInterval: UpdateIntervalSetting = .normal
    @AppStorage("graphZoomDefault") private var graphZoomDefault: GraphHistoryZoom = .oneHour
    @AppStorage("appOpacity") private var appOpacity: Double = 1.0
    
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    
    var body: some View {
        Form {
            Section(header: Text("General")) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Failed to update Launch at Login: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                
                Picker("Menu Bar Style", selection: $menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                
                Picker("Update Interval", selection: $updateInterval) {
                    ForEach(UpdateIntervalSetting.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            }

            Section(header: Text("Appearance")) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Window Transparency")
                        Spacer()
                        Text("\(Int(appOpacity * 100))%")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                    Slider(value: $appOpacity, in: 0.1...1.0)
                }
            }
            
            Section(header: Text("Graph")) {
                Picker("Default Graph Zoom", selection: $graphZoomDefault) {
                    ForEach(GraphHistoryZoom.allCases) { zoom in
                        Text(zoom.label).tag(zoom)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}
