import Foundation
import IOKit
import IOKit.ps
import AppKit

// Process names suppressed from the "Background Processes" view — pure OS noise
// that would otherwise clutter the list without being user-actionable.
private let backgroundProcessBlockList: Set<String> = [
    "finder", "windowserver", "dock", "loginwindow", "launchd",
    "kernel_task", "mds", "mdworker", "mds_stores", "spotlight",
    "systemuiserver", "controlcenter", "notificationcenter",
    "usernotificationcenter", "hidd", "commcenter",
    "nsurlsessiond", "trustd", "configd"
]

// MARK: - Data point for sparklines
struct AppMetricPoint: Identifiable, Equatable {
    let id: Int
    let time: Date
    let cpu: Double
    let power: Double
}

struct AppEnergyUsage: Identifiable {
    var id: String { appName }
    let appName: String
    let energyImpact: Double
    let cpuUsage: Double
    let ramUsage: String
    let history: [AppMetricPoint]
    let icon: NSImage?
}

@MainActor
class BatteryMonitor: ObservableObject {
    @Published var batteryLevel: Int = 0
    @Published var isCharging: Bool = false
    @Published var powerSource: String = "Unknown"
    @Published var timeRemaining: String = "Calculating…"
    @Published var batteryWatts: Double = 0.0
    @Published var topEnergyApps: [AppEnergyUsage] = []
    @Published var totalEnergyImpact: Double = 0.0
    
    @Published var systemCPU: String = "0%"
    @Published var systemCPUValue: Double = 0.0
    @Published var systemRAM: String = "0/0GB"
    @Published var systemRAMPercent: Double = 0.0
    @Published var memoryPressure: String = "Normal"
    @Published var memoryPressureState: Int = 0 // 0: Normal, 1: Warn, 2: Critical
    @Published var cpuTemperature: Double? = nil
    @Published var batteryHistory: [BatteryDataPoint] = [] {
        didSet {
            saveHistory()
        }
    }

    private var historyFileURL: URL? = {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let fluxDir = appSupport.appendingPathComponent("Flux")
        try? fileManager.createDirectory(at: fluxDir, withIntermediateDirectories: true)
        return fluxDir.appendingPathComponent("battery_history.json")
    }()

    private var appHistory: [String: [AppMetricPoint]] = [:]
    private let maxHistory = 720
    private var timer: Timer?
    private var topProcess: Process?
    private var smcReader = SMCReader()
    nonisolated(unsafe) private var psRunLoopSource: CFRunLoopSource?
    private static weak var current: BatteryMonitor?
    
    private let coreCount: Double = {
        var ncpu: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &size, nil, 0)
        return Double(ncpu > 0 ? ncpu : 1)
    }()

    private let totalRAMBytes: Int64 = {
        var size: Int64 = 0
        var sizeLen = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0)
        return size
    }()

    init() {
        print("DEBUG: BatteryMonitor initializing...")
        if !smcReader.open() {
            print("DEBUG: SMC open failed — CPU temperature unavailable.")
        }
        loadHistory()
        fetchBatteryInfo()
        fetchCPUTemperature()
        startMonitoring()
        startPowerSourceNotification()
        startTopStream()
    }

    private func loadHistory() {
        guard let url = historyFileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([BatteryDataPoint].self, from: data) {
            // Filter points older than 24h
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            self.batteryHistory = decoded.filter { $0.time > cutoff }
            print("DEBUG: Loaded \(batteryHistory.count) historical points.")
        }
    }

    private var lastSaveTime: Date = .distantPast
    private func saveHistory() {
        // Save at most once every 30 seconds to avoid disk churn
        let now = Date()
        guard now.timeIntervalSince(lastSaveTime) > 30 else { return }
        lastSaveTime = now
        
        guard let url = historyFileURL else { return }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(batteryHistory) {
            try? data.write(to: url)
        }
    }



    deinit {
        topProcess?.terminate()
        if let source = psRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        smcReader.close()
    }

    private func fetchCPUTemperature() {
        cpuTemperature = smcReader.readTemperature(
            keys: ["TC0P", "TC0E", "TC0D", "Tp01", "Tp05", "TaLC", "TCXC", "TCSC"]
        )
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchBatteryInfo()
                self?.fetchMemoryPressure()
                self?.fetchCPUTemperature()
            }
        }
    }

    private func startPowerSourceNotification() {
        BatteryMonitor.current = self
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in
                BatteryMonitor.current?.fetchBatteryInfo()
                BatteryMonitor.current?.fetchMemoryPressure()
            }
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        psRunLoopSource = source
    }

    private func fetchMemoryPressure() {
        var pressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("vm.memory_pressure", &pressure, &size, nil, 0) == 0 {
            // 0: Normal, 1: Warning, 2: Critical
            memoryPressureState = Int(pressure)
            switch pressure {
            case 1: memoryPressure = "Warn"
            case 2, 4: memoryPressure = "Critical" // Some OS versions use 4 for critical
            default: memoryPressure = "Normal"
            }
        }
    }

    func fetchBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            if let capacity = info[kIOPSCurrentCapacityKey] as? Int { batteryLevel = capacity }
            if let charging = info[kIOPSIsChargingKey] as? Bool { isCharging = charging }
            if let state = info[kIOPSPowerSourceStateKey] as? String {
                powerSource = (state == kIOPSACPowerValue) ? "AC Power" : "Battery"
            }
            if isCharging {
                if let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
                    let h = timeToFull / 60; let m = timeToFull % 60
                    timeRemaining = "\(h):\(String(format: "%02d", m)) until full"
                } else { timeRemaining = "Charging" }
            } else {
                if let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
                    let h = timeToEmpty / 60; let m = timeToEmpty % 60
                    timeRemaining = "\(h):\(String(format: "%02d", m)) remaining"
                } else { timeRemaining = "Calculating…" }
            }
            
            fetchBatteryWatts()

            // Update history
            let now = Date()
            let newPoint = BatteryDataPoint(id: (batteryHistory.last?.id ?? -1) + 1, time: now, level: batteryLevel)
            
            // Only add if level changed or enough time passed (e.g. 1 min) to avoid over-sampling, 
            // but for a smooth graph every 10s is fine if we prune.
            batteryHistory.append(newPoint)
            
            // Prune history older than 24 hours
            let twentyFourHoursAgo = now.addingTimeInterval(-24 * 3600)
            batteryHistory.removeAll { $0.time < twentyFourHoursAgo }
        }
    }

    /// Reads instantaneous battery power draw/charge from the IORegistry
    /// `AppleSmartBattery` entry. The IOPS power-source dictionary does not
    /// expose amperage/voltage, so we have to go to the registry directly.
    private func fetchBatteryWatts() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }

        // Amperage is signed (negative while discharging) and may be reported
        // as a 64-bit two's-complement value; NSNumber preserves the sign.
        guard let mA = (dict["Amperage"] as? NSNumber)?.doubleValue,
              let mV = (dict["Voltage"] as? NSNumber)?.doubleValue else { return }

        batteryWatts = abs(mA * mV) / 1_000_000.0
    }

    private func startTopStream() {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // Also surface menu-bar extras and background helpers with minimal UI.
        let accessoryApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .accessory }
        let allApps = runningApps + accessoryApps
        let runningAppNames = allApps.compactMap { $0.localizedName }
        var runningAppIcons: [String: NSImage] = [:]
        for app in allApps {
            if let name = app.localizedName, let icon = app.icon { runningAppIcons[name] = icon }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "0", "-s", "5", "-stats", "pid,command,cpu,power,mem", "-o", "cpu"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        self.topProcess = process

        let fileHandle = pipe.fileHandleForReading
        
        Task.detached { [weak self] in
            for try await line in fileHandle.bytes.lines {
                guard let self = self else { break }
                await self.parseTopLine(line, appNames: runningAppNames, appIcons: runningAppIcons)
            }
        }

        do {
            try process.run()
        } catch {
            print("Failed to start top stream: \(error)")
        }
    }

    private var currentAppPowerMap: [String: Double] = [:]
    private var currentAppCPUMap:   [String: Double] = [:]
    private var currentAppMemMap:   [String: Int]    = [:]
    private var isDataLine = false

    nonisolated private func parseTopLine(_ line: String, appNames: [String], appIcons: [String: NSImage]) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        if trimmed.hasPrefix("CPU usage:") {
            let parts = trimmed.components(separatedBy: ",")
            if parts.count >= 3 {
                let userStr = parts[0].replacingOccurrences(of: "CPU usage: ", with: "").replacingOccurrences(of: "% user", with: "").trimmingCharacters(in: .whitespaces)
                let sysStr = parts[1].replacingOccurrences(of: "% sys", with: "").replacingOccurrences(of: "% sys", with: "").trimmingCharacters(in: .whitespaces)
                if let user = Double(userStr), let sys = Double(sysStr) {
                    let total = user + sys
                    await MainActor.run { 
                        self.systemCPU = String(format: "%.0f%%", total) 
                        self.systemCPUValue = total
                    }
                }
            }
        } else if trimmed.hasPrefix("PhysMem:") {
            let usedPart = trimmed.replacingOccurrences(of: "PhysMem: ", with: "").components(separatedBy: " ").first ?? ""
            let usedMB = parseMemToMB(usedPart)
            let totalMB = totalRAMBytes / (1024 * 1024)
            let totalGB = totalRAMBytes / (1024 * 1024 * 1024)
            let usedDisplay = usedMB >= 1024 ? String(format: "%.1fGB", Double(usedMB)/1024.0) : "\(usedMB)MB"
            await MainActor.run { 
                self.systemRAM = "\(usedDisplay)/\(totalGB)GB" 
                self.systemRAMPercent = Double(usedMB) / Double(totalMB) * 100.0
            }
        } else if trimmed.hasPrefix("PID") {
            await resetSampleState()
            await setParsing(true)
        } else if (trimmed.isEmpty || trimmed.hasPrefix("Processes:")) {
            if await getParsing() {
                await setParsing(false)
                await finalizeUIUpdate(appIcons: appIcons)
            }
        } else if await getParsing() {
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 5 else { return }
            let memStr = parts.last ?? "0B"
            let power  = Double(parts[parts.count - 2]) ?? 0.0
            let rawCpu = Double(parts[parts.count - 3]) ?? 0.0
            
            // Fixed await syntax
            let cores  = await getCoreCount()
            let cpu    = rawCpu / cores
            
            let commandName = parts[1..<(parts.count - 3)].joined(separator: " ")

            var matchedApp: String? = nil
            for appName in appNames {
                if commandName.localizedCaseInsensitiveContains(appName) || 
                   appName.localizedCaseInsensitiveContains(commandName.replacingOccurrences(of: "(", with: "").trimmingCharacters(in: .whitespaces)) {
                        matchedApp = appName; break
                    }
                }
            if let appName = matchedApp {
                await addToSample(appName: appName, power: power, cpu: cpu, memMB: parseMemToMB(memStr))
            } else if UserDefaults.standard.bool(forKey: "showBackgroundProcesses") {
                let baseName = commandName.components(separatedBy: "(").first?
                    .trimmingCharacters(in: .whitespaces) ?? commandName
                let lower = baseName.lowercased()
                let blocked = backgroundProcessBlockList.contains(lower)
                    || lower.hasPrefix("com.apple.")
                    || lower.hasPrefix("com.google.")
                let hasActivity = power > 0 || rawCpu > 3.0
                if !blocked && hasActivity {
                    await addToSample(appName: commandName, power: power, cpu: cpu, memMB: parseMemToMB(memStr))
                }
            }
        }
    }

    private func resetSampleState() async {
        await MainActor.run {
            currentAppPowerMap.removeAll()
            currentAppCPUMap.removeAll()
            currentAppMemMap.removeAll()
        }
    }
    private func setParsing(_ value: Bool) async { await MainActor.run { isDataLine = value } }
    private func getParsing() async -> Bool { await MainActor.run { isDataLine } }
    private func getCoreCount() async -> Double { await MainActor.run { coreCount } }
    
    private func addToSample(appName: String, power: Double, cpu: Double, memMB: Int) async {
        await MainActor.run {
            currentAppPowerMap[appName, default: 0.0] += power
            currentAppCPUMap[appName,   default: 0.0] += cpu
            currentAppMemMap[appName,   default: 0]   += memMB
        }
    }

    private func finalizeUIUpdate(appIcons: [String: NSImage]) async {
        await MainActor.run {
            let powerMap = currentAppPowerMap
            let cpuMap = currentAppCPUMap
            let memMap = currentAppMemMap
            
            for (appName, power) in powerMap {
                let cpu = cpuMap[appName] ?? 0.0
                var hist = self.appHistory[appName] ?? []
                let newID = (hist.last?.id ?? -1) + 1
                hist.append(AppMetricPoint(id: newID, time: Date(), cpu: cpu, power: power))
                if hist.count > self.maxHistory { hist.removeFirst() }
                self.appHistory[appName] = hist
            }

            var apps = powerMap.map { (name, power) -> AppEnergyUsage in
                let mb = memMap[name] ?? 0
                let ramDisplay = mb >= 1024 ? String(format: "%.1fGB", Double(mb)/1024.0) : "\(mb)MB"
                return AppEnergyUsage(
                    appName: name,
                    energyImpact: power,
                    cpuUsage: cpuMap[name] ?? 0.0,
                    ramUsage: ramDisplay,
                    history: self.appHistory[name] ?? [],
                    icon: appIcons[name]
                )
            }
            apps.sort { 
                if $0.energyImpact != $1.energyImpact { return $0.energyImpact > $1.energyImpact }
                return $0.cpuUsage > $1.cpuUsage
            }
            self.topEnergyApps = Array(apps.prefix(8))
            self.totalEnergyImpact = apps.reduce(0) { $0 + $1.energyImpact }
        }
    }
    
    nonisolated private func parseMemToMB(_ mem: String) -> Int {
        let valueStr = mem.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))
        guard let value = Double(valueStr) else { return 0 }
        let unit = mem.suffix(1).uppercased()
        switch unit {
        case "G": return Int(value * 1024)
        case "M": return Int(value)
        case "K": return Int(value / 1024)
        default:  return Int(value)
        }
    }
}
