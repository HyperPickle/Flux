import SwiftUI
import Charts
import AppKit

// MARK: - Battery chart data
struct BatteryDataPoint: Identifiable {
    let id: Int
    let time: Date
    let level: Int
}

// MARK: - Drain Level
enum DrainLevel {
    case low, medium, high, extreme
    init(totalImpact: Double) {
        switch totalImpact {
        case ..<20:  self = .low
        case 20..<60: self = .medium
        case 60..<150: self = .high
        default:      self = .extreme
        }
    }
    var label: String {
        switch self {
        case .low:     return "Low Drain"
        case .medium:  return "Moderate"
        case .high:    return "High Drain"
        case .extreme: return "Extreme"
        }
    }
    var color: Color {
        switch self {
        case .low:     return .green
        case .medium:  return .yellow
        case .high:    return .orange
        case .extreme: return .red
        }
    }
}

// MARK: - App Heat level
enum HeatLevel {
    case low, medium, high, critical
    init(power: Double, cpu: Double) {
        if power > 0 {
            switch power {
            case ..<5:    self = .low
            case 5..<20:  self = .medium
            case 20..<50: self = .high
            default:      self = .critical
            }
        } else {
            switch cpu {
            case ..<10:   self = .low
            case 10..<30: self = .medium
            case 30..<70: self = .high
            default:      self = .critical
            }
        }
    }
    var label: String {
        switch self {
        case .low:      return "Low"
        case .medium:   return "Medium"
        case .high:     return "High"
        case .critical: return "Critical"
        }
    }
    var color: Color {
        switch self {
        case .low:      return .secondary
        case .medium:   return Color(hue: 0.11, saturation: 0.85, brightness: 0.9)
        case .high:     return .orange
        case .critical: return .red
        }
    }
    var cardTint: Color {
        switch self {
        case .low:      return Color.primary.opacity(0.04)
        case .medium:   return Color.yellow.opacity(0.07)
        case .high:     return Color.orange.opacity(0.08)
        case .critical: return Color.red.opacity(0.08)
        }
    }
}

// MARK: - Main view
struct ContentView: View {
    @ObservedObject var monitor: BatteryMonitor
    @State private var expandedApp: String? = nil

    var dummyChartData: [BatteryDataPoint] {
        let now = Date()
        let current = monitor.batteryLevel > 0 ? monitor.batteryLevel : 50
        return [
            BatteryDataPoint(id: 0, time: now.addingTimeInterval(-12 * 3600), level: 100),
            BatteryDataPoint(id: 1, time: now.addingTimeInterval(-9 * 3600),  level: 85),
            BatteryDataPoint(id: 2, time: now.addingTimeInterval(-6 * 3600),  level: 60),
            BatteryDataPoint(id: 3, time: now.addingTimeInterval(-3 * 3600),  level: 45),
            BatteryDataPoint(id: 4, time: now,                                level: current),
        ]
    }

    var chartColor: Color {
        if monitor.isCharging          { return Color(hue: 0.45, saturation: 0.8, brightness: 0.9) }
        if monitor.batteryLevel <= 20  { return .red }
        if monitor.batteryLevel <= 40  { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ───────────────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(monitor.batteryLevel)%")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(chartColor)
                        
                        if monitor.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.title3)
                                .foregroundColor(chartColor)
                                .offset(y: -10)
                        }
                    }
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .offset(y: -4)
                }
                Spacer()
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // ── System Metrics Row ──────────────────────────────────
            HStack(spacing: 8) {
                let cpuColor = getCPUColor(monitor.systemCPUValue)
                MetricPill(label: "CPU", value: monitor.systemCPU, icon: "cpu", color: cpuColor)
                let drain = DrainLevel(totalImpact: monitor.totalEnergyImpact)
                MetricPill(label: "DRAIN", value: drain.label, icon: "bolt", color: drain.color)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // ── Battery chart ────────────────────────────────────────
            Chart(dummyChartData) { point in
                LineMark(x: .value("T", point.time), y: .value("L", point.level))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(chartColor)
                AreaMark(x: .value("T", point.time), y: .value("L", point.level))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [chartColor.opacity(monitor.isCharging ? 0.35 : 0.2), chartColor.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 60)
            .padding(.horizontal, 16)

            // ── Processes ───────────────────────────────────────────
            Divider().padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Text("Process Overview")
                .font(.system(size: 9, weight: .bold)).foregroundColor(.secondary).textCase(.uppercase).tracking(0.5)
                .padding(.horizontal, 16).padding(.bottom, 8)

            if !monitor.topEnergyApps.isEmpty {
                VStack(spacing: 6) {
                    ForEach(monitor.topEnergyApps) { app in
                        AppCard(
                            app: app,
                            isExpanded: expandedApp == app.appName,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    expandedApp = (expandedApp == app.appName) ? nil : app.appName
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Starting Stream...").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }

            Color.clear.frame(height: 16)
        }
        .frame(width: 280)
    }

    private var statusText: String {
        if monitor.isCharging && monitor.batteryLevel == 100 { return "Fully Charged" }
        else if monitor.isCharging { return "Charging" }
        else { return monitor.timeRemaining }
    }
    
    private func getCPUColor(_ val: Double) -> Color {
        if val < 35 { return .green }
        if val < 75 { return .yellow }
        return .red
    }
}

struct MetricPill: View {
    let label: String; let value: String; let icon: String; let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8))
            Text(value).font(.system(size: 9, weight: .bold, design: .rounded))
        }
        .foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.15), lineWidth: 1))
    }
}

struct AppCard: View {
    let app: AppEnergyUsage
    let isExpanded: Bool
    let onTap: () -> Void
    private var heat: HeatLevel { HeatLevel(power: app.energyImpact, cpu: app.cpuUsage) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "app.fill").frame(width: 20, height: 20).foregroundColor(.secondary)
                    }
                    Text(app.appName).font(.system(size: 11, weight: .medium)).foregroundColor(.primary).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", app.cpuUsage)).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.secondary).frame(width: 35, alignment: .trailing)
                    Text(heat.label).font(.system(size: 9, weight: .bold)).foregroundColor(heat.color).frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 10).padding(.top, -6)
                AppDetailView(app: app, heat: heat)
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 10)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .bottom)), removal: .opacity))
            }
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 8).fill(heat.cardTint))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(heat.color.opacity(0.12), lineWidth: 1))
    }
}

struct AppDetailView: View {
    let app: AppEnergyUsage
    let heat: HeatLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CPU History (60s)").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary).textCase(.uppercase)
            
            HStack(alignment: .center, spacing: 12) {
                if app.history.count >= 2 {
                    Chart(app.history) { pt in
                        LineMark(x: .value("x", pt.id), y: .value("y", pt.cpu))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(heat.color)
                        AreaMark(x: .value("x", pt.id), y: .value("y", pt.cpu))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [heat.color.opacity(0.15), heat.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    // REMOVED includesZero: true to ensure graph starts at the very first point on the left
                    .chartXScale(domain: app.history.first!.id...app.history.last!.id)
                    .chartYScale(domain: .automatic(includesZero: true))
                    .frame(height: 50)
                    .padding(.leading, -4)
                    .animation(nil, value: app.history)
                } else {
                    Rectangle().fill(Color.clear).frame(height: 50)
                }
                
                VStack(spacing: 6) {
                    DetailStat(label: "CPU", value: String(format: "%.0f%%", app.cpuUsage))
                    DetailStat(label: "RAM", value: app.ramUsage)
                }
                .frame(width: 75)
            }
        }
        .frame(height: 70)
    }
}

struct DetailStat: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 7, weight: .bold)).foregroundColor(.secondary)
            Text(value).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.primary)
        }
        .padding(4).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
