import Foundation
import IOKit.ps
import AppKit

// MARK: - Data point for sparklines
struct AppMetricPoint: Identifiable, Equatable {
    let id: Int
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
    @Published var topEnergyApps: [AppEnergyUsage] = []
    @Published var totalEnergyImpact: Double = 0.0
    @Published var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    
    @Published var systemCPU: String = "0%"
    @Published var systemCPUValue: Double = 0.0
    @Published var systemRAM: String = "0/0GB"
    @Published var systemRAMPercent: Double = 0.0

    private var appHistory: [String: [AppMetricPoint]] = [:]
    private let maxHistory = 15
    private var timer: Timer?
    private var topProcess: Process?
    
    private let totalRAMBytes: Int64 = {
        var size: Int64 = 0
        var sizeLen = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0)
        return size
    }()

    init() {
        fetchBatteryInfo()
        startMonitoring()
        startTopStream()
    }

    deinit {
        topProcess?.terminate()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchBatteryInfo()
                self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
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
                } else { timeRemaining = "On Battery" }
            }
        }
    }

    private func startTopStream() {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningAppNames = runningApps.compactMap { $0.localizedName }
        var runningAppIcons: [String: NSImage] = [:]
        for app in runningApps {
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
                let sysStr = parts[1].replacingOccurrences(of: "% sys", with: "").trimmingCharacters(in: .whitespaces)
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
            let cpu    = Double(parts[parts.count - 3]) ?? 0.0
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
                hist.append(AppMetricPoint(id: newID, cpu: cpu, power: power))
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
            self.topEnergyApps = Array(apps.prefix(5))
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
