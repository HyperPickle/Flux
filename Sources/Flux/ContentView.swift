import SwiftUI
import Charts
import AppKit
import Foundation
import IOKit.ps

// MARK: - Battery chart data
struct BatteryDataPoint: Identifiable, Codable, Equatable {
    let id: Int
    let time: Date
    let level: Int
}

struct BatteryRenderPoint: Identifiable, Equatable {
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

struct InteractiveBatteryChart: View {
    @ObservedObject var monitor: BatteryMonitor
    let chartColor: Color
    let unknownLineColor: Color

    @State private var hoveredPoint: BatteryDataPoint? = nil
    @State private var tooltipX: CGFloat = 0
    @State private var tooltipY: CGFloat = 0
    @State private var zoomHours: Double = 6.0
    @State private var cachedBatteryHistory: [BatteryDataPoint] = []
    @State private var cachedSmoothedHistory: [BatteryRenderPoint] = []
    @State private var cachedChargingHistory: [BatteryRenderPoint] = []
    
    private static let tooltipTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    
    private let maxRenderedPoints = 320

    var batteryHistory: [BatteryDataPoint] {
        cachedBatteryHistory
    }
    
    private var zoomFilteredHistory: [BatteryDataPoint] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-zoomHours * 3600)
        return monitor.batteryHistory
            .filter { $0.time >= cutoff }
    }
    
    private var computedSmoothedHistory: [BatteryRenderPoint] {
        guard !zoomFilteredHistory.isEmpty else { return [] }
        
        var smoothed: [BatteryRenderPoint] = []
        smoothed.reserveCapacity(zoomFilteredHistory.count)
        
        // Lightweight EMA keeps performance high while removing visual stair-stepping.
        let alpha = 0.25
        var ema = Double(zoomFilteredHistory[0].level)
        
        for point in zoomFilteredHistory {
            ema += alpha * (Double(point.level) - ema)
            smoothed.append(BatteryRenderPoint(id: point.id, time: point.time, level: ema))
        }
        
        return downsampleIfNeeded(smoothed)
    }
    
    private var computedChargingHistory: [BatteryRenderPoint] {
        guard monitor.isCharging, computedSmoothedHistory.count > 1 else { return [] }
        
        // Find the start of the charging session in the FULL history,
        // to avoid incorrect mapping when zoomed out.
        let fullHistory = monitor.batteryHistory
        var startChargingDate = Date()
        
        if !fullHistory.isEmpty {
            let levels = fullHistory.map(\.level)
            var startIndex = max(0, levels.count - 1)

            // Walk backward from "now" to find where the current charging stretch began.
            for i in stride(from: levels.count - 1, through: 1, by: -1) {
                if levels[i - 1] > levels[i] {
                    startIndex = i
                    break
                }
                startIndex = i - 1
            }
            startChargingDate = fullHistory[startIndex].time
        }

        // Return only the smoothed points that are on or after the start charging date
        return computedSmoothedHistory.filter { $0.time >= startChargingDate }
    }

    private func downsampleIfNeeded(_ points: [BatteryRenderPoint]) -> [BatteryRenderPoint] {
        guard points.count > maxRenderedPoints else { return points }
        let strideValue = max(1, points.count / maxRenderedPoints)
        var reduced: [BatteryRenderPoint] = []
        reduced.reserveCapacity((points.count / strideValue) + 2)

        for index in Swift.stride(from: 0, to: points.count, by: strideValue) {
            reduced.append(points[index])
        }
        
        if let last = points.last, reduced.last?.id != last.id {
            reduced.append(last)
        }

        return reduced
    }

    private func recalculateChartData() {
        let filtered = zoomFilteredHistory
        let smoothed = computedSmoothedHistory
        let charging = computedChargingHistory

        if cachedBatteryHistory != filtered {
            cachedBatteryHistory = filtered
        }
        if cachedSmoothedHistory != smoothed {
            cachedSmoothedHistory = smoothed
        }
        if cachedChargingHistory != charging {
            cachedChargingHistory = charging
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                BatterySparklineCanvas(
                    smoothedPoints: cachedSmoothedHistory,
                    chargingPoints: cachedChargingHistory,
                    hoveredPoint: hoveredPoint,
                    batteryLevel: monitor.batteryLevel,
                    chartColor: chartColor,
                    unknownLineColor: unknownLineColor,
                    isCharging: monitor.isCharging,
                    zoomHours: zoomHours
                )

                ScrollDetector(
                    zoomHours: $zoomHours,
                    hoveredPoint: $hoveredPoint,
                    tooltipX: $tooltipX,
                    tooltipY: $tooltipY,
                    plotFrame: geo.frame(in: .local),
                    batteryHistory: batteryHistory,
                    batteryLevel: monitor.batteryLevel
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 60)
            .onDisappear {
                hoveredPoint = nil
            }

            // Zoom label
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(hovered.level)%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(chartColor)
                    Text(InteractiveBatteryChart.tooltipTimeFormatter.string(from: hovered.time))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(chartColor.opacity(0.25), lineWidth: 1))
                .offset(x: min(max(tooltipX - 28, 0), 210), y: tooltipY > 30 ? -2 : 30)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            recalculateChartData()
        }
        .onChange(of: zoomHours) { _ in
            recalculateChartData()
        }
        .onChange(of: monitor.batteryHistory) { _ in
            recalculateChartData()
        }
        .onChange(of: monitor.isCharging) { _ in
            recalculateChartData()
        }
    }
}

// MARK: - Main view
struct ContentView: View {
    @ObservedObject var monitor: BatteryMonitor
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedApp: String? = nil

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

                Toggle(isOn: Binding(
                    get: { monitor.isLowPowerMode },
                    set: { monitor.setLowPowerMode($0) }
                )) {
                    Text("Low Power Mode")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 4)
                .padding(.trailing, 8)

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
            InteractiveBatteryChart(
                monitor: monitor,
                chartColor: chartColor,
                unknownLineColor: unknownLineColor
            )
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

struct BatterySparklineCanvas: View {
    let smoothedPoints: [BatteryRenderPoint]
    let chargingPoints: [BatteryRenderPoint]
    let hoveredPoint: BatteryDataPoint?
    let batteryLevel: Int
    let chartColor: Color
    let unknownLineColor: Color
    let isCharging: Bool
    let zoomHours: Double
    
    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            let now = Date()
            let startDate = now.addingTimeInterval(-zoomHours * 3600)
            let bottomY = size.height
            
            func x(for date: Date) -> CGFloat {
                let total = max(now.timeIntervalSince(startDate), 1)
                let elapsed = date.timeIntervalSince(startDate)
                let ratio = min(max(elapsed / total, 0), 1)
                return CGFloat(ratio) * size.width
            }
            
            func y(for level: Double) -> CGFloat {
                let clamped = min(max(level, 0), 100)
                return size.height - (CGFloat(clamped) / 100.0) * size.height
            }
            
            func linePath(points: [BatteryRenderPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: CGPoint(x: x(for: first.time), y: y(for: first.level)))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: x(for: point.time), y: y(for: point.level)))
                }
                return path
            }
            
            // Missing-data hint when there is no visible history in this window.
            if smoothedPoints.isEmpty {
                let yPos = y(for: Double(batteryLevel))
                var dashPath = Path()
                dashPath.move(to: CGPoint(x: 0, y: yPos))
                dashPath.addLine(to: CGPoint(x: size.width, y: yPos))
                context.stroke(dashPath, with: .color(unknownLineColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else if let first = smoothedPoints.first {
                let gapThreshold = startDate.addingTimeInterval(300)
                if first.time > gapThreshold {
                    let gapEndX = x(for: first.time)
                    let gapY = y(for: first.level)
                    var gapPath = Path()
                    gapPath.move(to: CGPoint(x: 0, y: gapY))
                    gapPath.addLine(to: CGPoint(x: gapEndX, y: gapY))
                    context.stroke(gapPath, with: .color(unknownLineColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            
            if !smoothedPoints.isEmpty {
                let fillGradient = Gradient(colors: [chartColor.opacity(isCharging ? 0.35 : 0.2), chartColor.opacity(0.0)])
                var areaPath = linePath(points: smoothedPoints)
                if let last = smoothedPoints.last, let first = smoothedPoints.first {
                    areaPath.addLine(to: CGPoint(x: x(for: last.time), y: bottomY))
                    areaPath.addLine(to: CGPoint(x: x(for: first.time), y: bottomY))
                    areaPath.closeSubpath()
                    context.fill(areaPath, with: .linearGradient(fillGradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: bottomY)))
                }
                
                let strokePath = linePath(points: smoothedPoints)
                context.stroke(strokePath, with: .color(chartColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            
            if isCharging, !chargingPoints.isEmpty {
                let chargingGradient = Gradient(colors: [chartColor.opacity(0.6), chartColor.opacity(0.15)])
                var chargingPath = linePath(points: chargingPoints)
                if let last = chargingPoints.last, let first = chargingPoints.first {
                    chargingPath.addLine(to: CGPoint(x: x(for: last.time), y: bottomY))
                    chargingPath.addLine(to: CGPoint(x: x(for: first.time), y: bottomY))
                    chargingPath.closeSubpath()
                    context.fill(chargingPath, with: .linearGradient(chargingGradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: bottomY)))
                }
            }
            
            if let hoveredPoint {
                let hoverX = x(for: hoveredPoint.time)
                let hoverY = y(for: Double(hoveredPoint.level))
                
                var guidePath = Path()
                guidePath.move(to: CGPoint(x: hoverX, y: 0))
                guidePath.addLine(to: CGPoint(x: hoverX, y: bottomY))
                context.stroke(guidePath, with: .color(chartColor.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                
                let dotRect = CGRect(x: hoverX - 3, y: hoverY - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dotRect), with: .color(chartColor))
            }
        }
        .drawingGroup()
    }
}

struct ScrollDetector: NSViewRepresentable {
    @Binding var zoomHours: Double
    @Binding var hoveredPoint: BatteryDataPoint?
    @Binding var tooltipX: CGFloat
    @Binding var tooltipY: CGFloat
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
            let clampedRatio = min(max(plotX / max(plotFrame.width, 1), 0), 1)
            let windowSeconds = zoomHours * 3600
            let date = Date().addingTimeInterval(-windowSeconds + (clampedRatio * windowSeconds))
            
            if let nearest = nearestPoint(to: date, in: batteryHistory) {
                if hoveredPoint?.id != nearest.id {
                    hoveredPoint = nearest
                }
                
                let newTooltipY = plotFrame.maxY - location.y
                if abs(tooltipX - location.x) > 0.75 {
                    tooltipX = location.x
                }
                if abs(tooltipY - newTooltipY) > 0.75 {
                    tooltipY = newTooltipY
                }
            } else if batteryHistory.isEmpty {
                if hoveredPoint?.id != -1 || hoveredPoint?.time != date {
                    hoveredPoint = BatteryDataPoint(id: -1, time: date, level: batteryLevel)
                }
                
                let newTooltipY = plotFrame.maxY - location.y
                if abs(tooltipX - location.x) > 0.75 {
                    tooltipX = location.x
                }
                if abs(tooltipY - newTooltipY) > 0.75 {
                    tooltipY = newTooltipY
                }
            } else {
                hoveredPoint = nil
            }
        }
    }
    
    private func nearestPoint(to date: Date, in history: [BatteryDataPoint]) -> BatteryDataPoint? {
        guard !history.isEmpty else { return nil }
        
        var low = 0
        var high = history.count - 1
        
        while low < high {
            let mid = (low + high) / 2
            if history[mid].time < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        
        let right = low
        let left = max(0, right - 1)
        
        let leftPoint = history[left]
        let rightPoint = history[right]
        
        if abs(leftPoint.time.timeIntervalSince(date)) <= abs(rightPoint.time.timeIntervalSince(date)) {
            return leftPoint
        } else {
            return rightPoint
        }
    }
    
    class ScrollNSView: NSView {
        var onScroll: ((Double) -> Void)?
        var onHover: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?
        
        private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: NSPoint.zero)

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            self
        }
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: Self.invisibleCursor)
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
