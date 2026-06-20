import SwiftUI
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconOnly = "Icon Only"
    case battery = "Battery"
    case time = "Time"
    case batteryAndTime = "Battery + Time"
    var id: Self { self }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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

struct SettingsPaneView: View {
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .iconOnly
    @AppStorage("graphZoomDefault") private var graphZoomDefault: GraphHistoryZoom = .sixHours
    @AppStorage("appOpacity") private var appOpacity: Double = 1.0
    @AppStorage("compactTime") private var compactTime: Bool = false
    @AppStorage("compactBattery") private var compactBattery: Bool = false

    @State private var launchAtLogin = false
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ────────────────────────────────────────────────
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // Invisible balance for the Back button
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // ── Settings content ──────────────────────────────────────
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {

                    // APPEARANCE: theme + opacity + menu bar style
                    SettingsGroupView(title: "Appearance") {
                        SettingsPickerRow(label: "Theme", selection: $appAppearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.rawValue).tag(appearance)
                            }
                        }
                        Divider().padding(.horizontal, 11)
                        SettingsSliderRow(label: "Opacity", value: $appOpacity, in: 0.1...1.0)
                        Divider().padding(.horizontal, 11)
                        SettingsPickerRow(label: "Menu Bar", selection: $menuBarStyle) {
                            ForEach(MenuBarStyle.allCases) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        if menuBarStyle == .time {
                            Divider().padding(.horizontal, 11)
                            SettingsToggleRow(label: "Show time only", isOn: $compactTime)
                        }
                        if menuBarStyle == .battery {
                            Divider().padding(.horizontal, 11)
                            SettingsToggleRow(label: "Show percentage only", isOn: $compactBattery)
                        }
                        if menuBarStyle == .batteryAndTime {
                            Divider().padding(.horizontal, 11)
                            SettingsToggleRow(label: "Show percentage only", isOn: $compactBattery)
                            Divider().padding(.horizontal, 11)
                            SettingsToggleRow(label: "Show time only", isOn: $compactTime)
                        }
                    }

                    // GENERAL (graph zoom + launch at login)
                    SettingsGroupView(title: "General") {
                        SettingsPickerRow(label: "Default Zoom", selection: $graphZoomDefault) {
                            ForEach(GraphHistoryZoom.allCases) { zoom in
                                Text(zoom.label).tag(zoom)
                            }
                        }
                        Divider().padding(.horizontal, 11)
                        SettingsToggleRow(
                            label: "Launch at Login",
                            isOn: Binding(
                                get: { launchAtLogin },
                                set: { newValue in
                                    launchAtLogin = newValue
                                    do {
                                        if newValue { try SMAppService.mainApp.register() }
                                        else { try SMAppService.mainApp.unregister() }
                                    } catch {
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                    }
                                }
                            )
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            // Size the scroll content to its natural height so the window grows
            // to fit every visible option (no internal scrolling) without leaving
            // empty space at the bottom when fewer options are shown.
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct SettingsGroupView<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        }
    }
}

struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }
}

struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    let label: String
    @Binding var selection: SelectionValue
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).fixedSize()
            Spacer()
            Picker("", selection: $selection) { content() }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 12))
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
    }
}

struct SettingsSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(label: String, value: Binding<Double>, in range: ClosedRange<Double>) {
        self.label = label
        self._value = value
        self.range = range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }
}
