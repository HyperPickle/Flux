import Foundation
import IOKit
import IOKit.ps
import AppKit

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
    let smoothedHistory: [AppMetricPoint]
    let icon: NSImage?
}

enum ProcessRole: Equatable, Sendable {
    case primaryApp
    case helper(ownerPID: Int32)
    case hidden
}

struct RunningProcessMetadata: Equatable, Sendable {
    enum ActivationPolicy: Equatable, Sendable {
        case regular
        case accessory
        case prohibited
    }

    let pid: Int32
    let name: String?
    let bundleIdentifier: String?
    let bundleURLPath: String?
    let activationPolicy: ActivationPolicy
}

struct ProcessOwnershipResolution: Equatable, Sendable {
    let roleByPID: [Int32: ProcessRole]
    let displayOwnerByPID: [Int32: String]
}

struct ProcessDisplayIdentityResolver {
    func iconsByOwner(
        resolution: ProcessOwnershipResolution,
        primaryIconsByPID: [Int32: NSImage]
    ) -> [String: NSImage] {
        var result: [String: NSImage] = [:]
        for (pid, role) in resolution.roleByPID where role == .primaryApp {
            guard let name = resolution.displayOwnerByPID[pid],
                  let icon = primaryIconsByPID[pid] else { continue }
            result[name] = icon
        }
        return result
    }
}

/// Resolves background processes to a user-facing regular application. Unknown
/// processes are deliberately hidden instead of becoming noisy standalone rows.
struct ProcessOwnershipResolver: Sendable {
    func resolve(_ processes: [RunningProcessMetadata]) -> ProcessOwnershipResolution {
        let primaryApps = processes.filter { $0.activationPolicy == .regular && $0.name != nil }
        let safari = primaryApps.first { process in
            process.name?.caseInsensitiveCompare("Safari") == .orderedSame ||
                process.bundleIdentifier == "com.apple.Safari"
        }

        var roles: [Int32: ProcessRole] = [:]
        var owners: [Int32: String] = [:]

        for process in processes {
            if process.activationPolicy == .regular, let name = process.name {
                roles[process.pid] = .primaryApp
                owners[process.pid] = name
                continue
            }

            let owner = nestedBundleOwner(for: process, among: primaryApps)
                ?? derivedBundleIdentifierOwner(for: process, among: primaryApps)
                ?? safariOwner(for: process, safari: safari)
                ?? helperNameOwner(for: process, among: primaryApps)

            if let owner, let ownerName = owner.name {
                roles[process.pid] = .helper(ownerPID: owner.pid)
                owners[process.pid] = ownerName
            } else {
                roles[process.pid] = .hidden
            }
        }

        return ProcessOwnershipResolution(roleByPID: roles, displayOwnerByPID: owners)
    }

    private func nestedBundleOwner(
        for process: RunningProcessMetadata,
        among primaryApps: [RunningProcessMetadata]
    ) -> RunningProcessMetadata? {
        guard let childPath = process.bundleURLPath else { return nil }
        return primaryApps
            .filter { primary in
                guard let parentPath = primary.bundleURLPath else { return false }
                return childPath.hasPrefix(parentPath + "/")
            }
            .max { ($0.bundleURLPath?.count ?? 0) < ($1.bundleURLPath?.count ?? 0) }
    }

    private func derivedBundleIdentifierOwner(
        for process: RunningProcessMetadata,
        among primaryApps: [RunningProcessMetadata]
    ) -> RunningProcessMetadata? {
        guard let childIdentifier = process.bundleIdentifier else { return nil }
        return primaryApps
            .filter { primary in
                guard let parentIdentifier = primary.bundleIdentifier else { return false }
                return childIdentifier.hasPrefix(parentIdentifier + ".")
            }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    private func safariOwner(
        for process: RunningProcessMetadata,
        safari: RunningProcessMetadata?
    ) -> RunningProcessMetadata? {
        guard let safari else { return nil }
        let identifier = process.bundleIdentifier?.lowercased() ?? ""
        let name = process.name?.lowercased() ?? ""
        let isWebKitChild = identifier.hasPrefix("com.apple.webkit.") ||
            name.hasPrefix("com.apple.webkit.") ||
            name.hasPrefix("webkit") ||
            name.contains("safari web content") ||
            name.contains("safari networking") ||
            name.contains("safari graphics and media")
        return isWebKitChild ? safari : nil
    }

    private func helperNameOwner(
        for process: RunningProcessMetadata,
        among primaryApps: [RunningProcessMetadata]
    ) -> RunningProcessMetadata? {
        guard let childName = process.name?.lowercased() else { return nil }
        return primaryApps
            .filter { primary in
                guard let parentName = primary.name?.lowercased() else { return false }
                return childName.hasPrefix(parentName + " helper")
            }
            .max { ($0.name?.count ?? 0) < ($1.name?.count ?? 0) }
    }
}

struct TopFrame: Sendable {
    var powerByApp: [String: Double] = [:]
    var cpuByApp: [String: Double] = [:]
    var memoryByApp: [String: Int] = [:]
    var systemCPUUser: Double = 0
    var systemCPUSystem: Double = 0
    var usedMemoryMB: Int = 0
}

/// Parses `top` output off the main actor. Logging-mode `top` reports cumulative
/// values in its first frame, so only the second frame is returned.
struct TopFrameParser: Sendable {
    let displayOwnerByPID: [Int32: String]

    private var frame = TopFrame()
    private var isReadingProcesses = false
    private var completedFrameCount = 0

    mutating func consume(_ line: String) -> TopFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("CPU usage:") {
            let parts = trimmed.components(separatedBy: ",")
            if parts.count >= 2 {
                frame.systemCPUUser = percentage(parts[0].replacingOccurrences(of: "CPU usage:", with: ""))
                frame.systemCPUSystem = percentage(parts[1])
            }
        } else if trimmed.hasPrefix("PhysMem:") {
            let used = trimmed.replacingOccurrences(of: "PhysMem:", with: "")
                .split(separator: " ").first.map(String.init) ?? "0B"
            frame.usedMemoryMB = Self.memoryInMB(used)
        } else if trimmed.hasPrefix("PID") {
            frame.powerByApp.removeAll(keepingCapacity: true)
            frame.cpuByApp.removeAll(keepingCapacity: true)
            frame.memoryByApp.removeAll(keepingCapacity: true)
            isReadingProcesses = true
        } else if (trimmed.isEmpty || trimmed.hasPrefix("Processes:")), isReadingProcesses {
            isReadingProcesses = false
            completedFrameCount += 1
            return completedFrameCount > 1 ? frame : nil
        } else if isReadingProcesses {
            consumeProcessRow(trimmed)
        }

        return nil
    }

    mutating func finish() -> TopFrame? {
        guard isReadingProcesses else { return nil }
        isReadingProcesses = false
        completedFrameCount += 1
        return completedFrameCount > 1 ? frame : nil
    }

    private mutating func consumeProcessRow(_ line: String) {
        let parts = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard parts.count >= 5, let pid = Int32(parts[0]) else { return }

        let memory = Self.memoryInMB(parts.last ?? "0B")
        let power = Double(parts[parts.count - 2]) ?? 0
        // Keep Activity Monitor's per-core convention: one saturated core is 100%.
        let cpu = Double(parts[parts.count - 3]) ?? 0
        guard let appName = displayOwnerByPID[pid] else { return }
        frame.powerByApp[appName, default: 0] += power
        frame.cpuByApp[appName, default: 0] += cpu
        frame.memoryByApp[appName, default: 0] += memory
    }

    private func percentage(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: "% user", with: "")
            .replacingOccurrences(of: "% sys", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static func memoryInMB(_ memory: String) -> Int {
        let valueString = memory.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))
        guard let value = Double(valueString) else { return 0 }
        switch memory.suffix(1).uppercased() {
        case "G": return Int(value * 1024)
        case "M": return Int(value)
        case "K": return Int(value / 1024)
        default: return Int(value)
        }
    }
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
    @Published var systemCPUUser: Double = 0.0
    @Published var systemCPUSys: Double = 0.0
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
    private var appLastSeenSample: [String: Int] = [:]
    private var sampleNumber = 0
    private let maxHistory = 720
    private var timer: Timer?
    private var topProcess: Process?
    nonisolated(unsafe) private var topSampleTimer: Timer?
    private var isDetailsVisible = false
    private var samplingGeneration = 0
    private var smcReader = SMCReader()
    nonisolated(unsafe) private var psRunLoopSource: CFRunLoopSource?
    private static weak var current: BatteryMonitor?

    private let totalRAMBytes: Int64 = {
        var size: Int64 = 0
        var sizeLen = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0)
        return size
    }()

    init() {
        #if DEBUG
        print("DEBUG: BatteryMonitor initializing...")
        #endif
        if !smcReader.open() {
            #if DEBUG
            print("DEBUG: SMC open failed — CPU temperature unavailable.")
            #endif
        }
        loadHistory()
        fetchBatteryInfo()
        fetchCPUTemperature()
        startMonitoring()
        startPowerSourceNotification()
    }

    private func loadHistory() {
        guard let url = historyFileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([BatteryDataPoint].self, from: data) {
            // Filter points older than 24h
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            self.batteryHistory = decoded.filter { $0.time > cutoff }
            #if DEBUG
            print("DEBUG: Loaded \(batteryHistory.count) historical points.")
            #endif
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
        topSampleTimer?.invalidate()
        topProcess?.terminate()
        if let source = psRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        smcReader.close()
    }

    private func fetchCPUTemperature() {
        cpuTemperature = smcReader.readTemperature(
            keys: [
                // Intel CPU die/proximity sensors (sp78)
                "TC0P", "TC0E", "TC0D",
                // Apple Silicon per-core sensors (flt). Averaged for a stable reading.
                "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T",
                "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n",
            ]
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

    func setDetailsVisible(_ visible: Bool) {
        guard visible != isDetailsVisible else { return }
        isDetailsVisible = visible
        samplingGeneration += 1

        if visible {
            runTopSample()
            topSampleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.runTopSample() }
            }
        } else {
            topSampleTimer?.invalidate()
            topSampleTimer = nil
            topProcess?.terminate()
            topProcess = nil
        }
    }

    private func runTopSample() {
        guard isDetailsVisible, topProcess == nil else { return }
        let generation = samplingGeneration
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let allApps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != ownPID else { return false }
            if let ownBundleIdentifier, app.bundleIdentifier == ownBundleIdentifier { return false }
            return true
        }
        let metadata = allApps.map { app in
            let activationPolicy: RunningProcessMetadata.ActivationPolicy
            switch app.activationPolicy {
            case .regular: activationPolicy = .regular
            case .accessory: activationPolicy = .accessory
            default: activationPolicy = .prohibited
            }
            return RunningProcessMetadata(
                pid: app.processIdentifier,
                name: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                bundleURLPath: app.bundleURL?.standardizedFileURL.path,
                activationPolicy: activationPolicy
            )
        }
        let ownership = ProcessOwnershipResolver().resolve(metadata)
        var primaryIconsByPID: [Int32: NSImage] = [:]
        for app in allApps where app.activationPolicy == .regular {
            if let icon = app.icon {
                primaryIconsByPID[app.processIdentifier] = icon
            } else if let bundleURL = app.bundleURL {
                // A folded helper always inherits the regular app's branding.
                primaryIconsByPID[app.processIdentifier] = NSWorkspace.shared.icon(forFile: bundleURL.path)
            }
        }
        let runningAppIcons = ProcessDisplayIdentityResolver().iconsByOwner(
            resolution: ownership,
            primaryIconsByPID: primaryIconsByPID
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", "1", "-stats", "pid,command,cpu,power,mem", "-o", "cpu"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        self.topProcess = process

        let fileHandle = pipe.fileHandleForReading
        
        Task.detached { [weak self] in
            var parser = TopFrameParser(
                displayOwnerByPID: ownership.displayOwnerByPID
            )
            var pending = Data()
            do {
                while let chunk = try fileHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[..<newline]
                        pending.removeSubrange(...newline)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        if let frame = parser.consume(line) {
                            await self?.publish(
                                frame: frame,
                                appIcons: runningAppIcons,
                                generation: generation
                            )
                        }
                    }
                }
                if let frame = parser.finish() {
                    await self?.publish(
                        frame: frame,
                        appIcons: runningAppIcons,
                        generation: generation
                    )
                }
            } catch {
                // Expected if closing the popover terminates the sample.
            }
            await self?.topSampleDidFinish(process)
        }

        do {
            try process.run()
        } catch {
            topProcess = nil
            print("Failed to start top stream: \(error)")
        }
    }

    private func topSampleDidFinish(_ process: Process) {
        if topProcess === process { topProcess = nil }
    }

    private func publish(frame: TopFrame, appIcons: [String: NSImage], generation: Int) {
        guard isDetailsVisible, generation == samplingGeneration else { return }
        currentAppPowerMap = frame.powerByApp
        currentAppCPUMap = frame.cpuByApp
        currentAppMemMap = frame.memoryByApp

        let totalCPU = frame.systemCPUUser + frame.systemCPUSystem
        systemCPU = String(format: "%.0f%%", totalCPU)
        systemCPUValue = totalCPU
        systemCPUUser = frame.systemCPUUser
        systemCPUSys = frame.systemCPUSystem

        let totalMB = totalRAMBytes / (1024 * 1024)
        let totalGB = totalRAMBytes / (1024 * 1024 * 1024)
        let usedMB = frame.usedMemoryMB
        let usedDisplay = usedMB >= 1024 ? String(format: "%.1fGB", Double(usedMB) / 1024) : "\(usedMB)MB"
        systemRAM = "\(usedDisplay)/\(totalGB)GB"
        systemRAMPercent = totalMB > 0 ? Double(usedMB) / Double(totalMB) * 100 : 0

        finalizeUIUpdate(appIcons: appIcons)
    }

    private var currentAppPowerMap: [String: Double] = [:]
    private var currentAppCPUMap:   [String: Double] = [:]
    private var currentAppMemMap:   [String: Int]    = [:]
    private func finalizeUIUpdate(appIcons: [String: NSImage]) {
        let powerMap = currentAppPowerMap
        let cpuMap = currentAppCPUMap
        let memMap = currentAppMemMap
        sampleNumber += 1
        
        for (appName, power) in powerMap {
            appLastSeenSample[appName] = sampleNumber
            let cpu = cpuMap[appName] ?? 0.0
            var hist = self.appHistory[appName] ?? []
            let newID = (hist.last?.id ?? -1) + 1
            hist.append(AppMetricPoint(id: newID, time: Date(), cpu: cpu, power: power))
            if hist.count > self.maxHistory { hist.removeFirst() }
            self.appHistory[appName] = hist
        }

        let staleNames = appLastSeenSample.compactMap { name, lastSeen in
            sampleNumber - lastSeen > 120 ? name : nil
        }
        for name in staleNames {
            appHistory.removeValue(forKey: name)
            appLastSeenSample.removeValue(forKey: name)
        }

        var apps = powerMap.map { (name, power) -> AppEnergyUsage in
            let mb = memMap[name] ?? 0
            let ramDisplay = mb >= 1024 ? String(format: "%.1fGB", Double(mb)/1024.0) : "\(mb)MB"
            let history = self.appHistory[name] ?? []
            let smoothedHistory = self.smoothed(history)
            return AppEnergyUsage(
                appName: name,
                energyImpact: smoothedHistory.last?.power ?? power,
                cpuUsage: smoothedHistory.last?.cpu ?? cpuMap[name] ?? 0.0,
                ramUsage: ramDisplay,
                history: history,
                smoothedHistory: smoothedHistory,
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

    private func smoothed(_ history: [AppMetricPoint]) -> [AppMetricPoint] {
        guard let first = history.first else { return [] }
        let alpha = 0.15
        var powerEMA = first.power
        var cpuEMA = first.cpu
        return history.map { point in
            powerEMA += alpha * (point.power - powerEMA)
            cpuEMA += alpha * (point.cpu - cpuEMA)
            return AppMetricPoint(id: point.id, time: point.time, cpu: cpuEMA, power: powerEMA)
        }
    }
    
}
