import SwiftUI
import Charts
import AppKit
import Foundation
import IOKit.ps

// MARK: - Battery chart data
struct BatteryDataPoint: Identifiable, Codable {
    let id: Int
    let time: Date
    let level: Int
}

struct BatteryRenderPoint: Identifiable {
    let id: Int
    let time: Date
    let level: Double
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedApp: String? = nil
    @State private var hoveredPoint: BatteryDataPoint? = nil
    @State private var tooltipX: CGFloat = 0
    @State private var tooltipY: CGFloat = 0
    @State private var zoomHours: Double = 6.0

    var batteryHistory: [BatteryDataPoint] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-zoomHours * 3600)
        return monitor.batteryHistory
            .filter { $0.time >= cutoff }
            .sorted { $0.time < $1.time }
    }
    
    var smoothedBatteryHistory: [BatteryRenderPoint] {
        guard !batteryHistory.isEmpty else { return [] }
        
        var smoothed: [BatteryRenderPoint] = []
        smoothed.reserveCapacity(batteryHistory.count)
        
        // Lightweight EMA keeps performance high while removing visual stair-stepping.
        let alpha = 0.25
        var ema = Double(batteryHistory[0].level)
        
        for point in batteryHistory {
            ema += alpha * (Double(point.level) - ema)
            smoothed.append(BatteryRenderPoint(id: point.id, time: point.time, level: ema))
        }
        
        return smoothed
    }
    
    var chargingPeriodHistory: [BatteryRenderPoint] {
        guard monitor.isCharging, smoothedBatteryHistory.count > 1 else { return [] }
        
        let levels = batteryHistory.map(\.level)
        var startIndex = max(0, levels.count - 1)
        
        // Walk backward from "now" to find where the current charging stretch began.
        for i in stride(from: levels.count - 1, through: 1, by: -1) {
            if levels[i - 1] > levels[i] {
                startIndex = i
                break
            }
            startIndex = i - 1
        }
        
        return Array(smoothedBatteryHistory.dropFirst(startIndex))
    }

    var chartColor: Color {
        if monitor.isCharging          { return Color(hue: 0.45, saturation: 0.8, brightness: 0.9) }
        if monitor.batteryLevel <= 20  { return .red }
        if monitor.batteryLevel <= 40  { return .orange }
        return .green
    }
    
    var unknownLineColor: Color {
        colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.45)
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
            ZStack(alignment: .topLeading) {
                Chart {
                    ForEach(smoothedBatteryHistory) { point in
                        LineMark(x: .value("T", point.time), y: .value("L", point.level))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(chartColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        
                        AreaMark(x: .value("T", point.time), y: .value("L", point.level))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(
                                colors: [chartColor.opacity(monitor.isCharging ? 0.35 : 0.2), chartColor.opacity(0)],
                                startPoint: .top, endPoint: .bottom))
                    }
                    
                    if monitor.isCharging {
                        ForEach(chargingPeriodHistory) { point in
                            AreaMark(x: .value("T", point.time), y: .value("L", point.level))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(chartColor.opacity(0.22))
                        }
                    }
                    
                    // Show dotted line for missing data
                    if batteryHistory.isEmpty {
                        RuleMark(y: .value("L", monitor.batteryLevel))
                            .foregroundStyle(unknownLineColor)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    } else if let first = batteryHistory.first {
                        let cutoff = Date().addingTimeInterval(-zoomHours * 3600)
                        if first.time > cutoff.addingTimeInterval(300) {
                            RuleMark(xStart: .value("T", cutoff), xEnd: .value("T", first.time), y: .value("L", first.level))
                                .foregroundStyle(unknownLineColor)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                    }
                    
                    if let hovered = hoveredPoint {
                        RuleMark(x: .value("T", hovered.time))
                            .foregroundStyle(chartColor.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(x: .value("T", hovered.time), y: .value("L", hovered.level))
                            .foregroundStyle(chartColor)
                            .symbolSize(30)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: Date().addingTimeInterval(-zoomHours * 3600)...Date())
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 60)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ScrollDetector(
                            zoomHours: $zoomHours,
                            hoveredPoint: $hoveredPoint,
                            tooltipX: $tooltipX,
                            tooltipY: $tooltipY,
                            proxy: proxy,
                            plotFrame: {
                                if #available(macOS 14, *) {
                                    if let anchor = proxy.plotFrame {
                                        return geo[anchor]
                                    }
                                }
                                return geo.frame(in: .local)
                            }(),
                            batteryHistory: batteryHistory,
                            batteryLevel: monitor.batteryLevel
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .onDisappear {
                    hoveredPoint = nil
                }

                // Zoom label (briefly shown when zooming?)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(Int(zoomHours))h")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.trailing, 4)
                            .padding(.bottom, 2)
                    }
                }
                .allowsHitTesting(false)

                // Floating tooltip
                if let hovered = hoveredPoint {
                    let timeStr = {
                        let f = DateFormatter()
                        f.dateFormat = "h:mm a"
                        return f.string(from: hovered.time)
                    }()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(hovered.level)%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(chartColor)
                        Text(timeStr)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(chartColor.opacity(0.25), lineWidth: 1))
                    .offset(x: min(max(tooltipX - 28, 0), 210), y: tooltipY > 30 ? -2 : 30)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.1), value: hovered.id)
                    .allowsHitTesting(false)
                }
            }
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
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
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
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.top, -6)
                
                AppDetailView(app: app, heat: heat)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
                        removal: .opacity
                    ))
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

struct ScrollDetector: NSViewRepresentable {
    @Binding var zoomHours: Double
    @Binding var hoveredPoint: BatteryDataPoint?
    @Binding var tooltipX: CGFloat
    @Binding var tooltipY: CGFloat
    let proxy: ChartProxy
    let plotFrame: CGRect
    let batteryHistory: [BatteryDataPoint]
    let batteryLevel: Int
    
    func makeNSView(context: Context) -> NSView {
        let view = ScrollNSView()
        configure(view)
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ScrollNSView else { return }
        configure(view)
    }
    
    private func configure(_ view: ScrollNSView) {
        view.onScroll = { delta in
            let factor: Double = 0.05
            var newZoom = zoomHours + (delta * factor)
            newZoom = max(1, min(24, newZoom))
            if zoomHours != newZoom {
                zoomHours = newZoom
            }
        }
        
        view.onHover = { location in
            guard let location else {
                hoveredPoint = nil
                return
            }
            
            guard plotFrame.contains(location) else {
                hoveredPoint = nil
                return
            }
            
            let plotX = location.x - plotFrame.origin.x
            let date: Date
            if let proxyDate: Date = proxy.value(atX: plotX) {
                date = proxyDate
            } else {
                let clampedRatio = min(max(plotX / max(plotFrame.width, 1), 0), 1)
                let windowSeconds = zoomHours * 3600
                date = Date().addingTimeInterval(-windowSeconds + (clampedRatio * windowSeconds))
            }
            
            if let nearest = batteryHistory.min(by: {
                abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
            }) {
                hoveredPoint = nearest
                tooltipX = location.x
                tooltipY = plotFrame.maxY - location.y
            } else if batteryHistory.isEmpty {
                hoveredPoint = BatteryDataPoint(id: -1, time: date, level: batteryLevel)
                tooltipX = location.x
                tooltipY = plotFrame.maxY - location.y
            } else {
                hoveredPoint = nil
            }
        }
    }
    
    class ScrollNSView: NSView {
        var onScroll: ((Double) -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?
        
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            self
        }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        
        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            
            let area = NSTrackingArea(
                rect: bounds,
                options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
            super.updateTrackingAreas()
        }
        
        override func mouseEntered(with event: NSEvent) {
            onHover?(convert(event.locationInWindow, from: nil))
        }
        
        override func mouseMoved(with event: NSEvent) {
            onHover?(convert(event.locationInWindow, from: nil))
        }
        
        override func mouseExited(with event: NSEvent) {
            onHover?(nil)
        }
        
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
        }
        
        override func scrollWheel(with event: NSEvent) {
            if event.scrollingDeltaY != 0 {
                onScroll?(-Double(event.scrollingDeltaY))
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}
