import Foundation
import IOKit

// MARK: - SMC C struct mirrors
// These must match the AppleSMC kernel struct byte layout exactly. Field order,
// sizes, and padding are load-bearing — see the size assertion in SMCReader.open().

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyData_keyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var _pad: (UInt8, UInt8, UInt8) = (0, 0, 0)   // C aligns this struct to 4 bytes
}

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyData_keyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var _pad: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - SMC reader

struct SMCReader {
    private var connection: io_connect_t = 0

    // SMC command bytes used in SMCKeyData.data8
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9
    // Selector index for IOConnectCallStructMethod (KERNEL_INDEX_SMC)
    private static let kernelIndexSMC: UInt32 = 2

    mutating func open() -> Bool {
        #if DEBUG
        assert(MemoryLayout<SMCKeyData>.size == 80,
               "SMCKeyData layout drifted: \(MemoryLayout<SMCKeyData>.size) bytes, expected 80")
        #endif

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        return result == kIOReturnSuccess
    }

    mutating func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// Averages every valid reading across the given keys. On Intel only one
    /// CPU key typically resolves; on Apple Silicon many per-core sensors do,
    /// and averaging them yields a stable, representative CPU temperature.
    /// Returns nil when no key produces a valid reading.
    func readTemperature(keys: [String]) -> Double? {
        guard connection != 0 else { return nil }
        var sum = 0.0
        var count = 0
        for key in keys {
            if let temp = readTemp(key: key) {
                sum += temp
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    private func readTemp(key: String) -> Double? {
        let keyCode = fourCC(key)

        // a. GetKeyInfo → dataSize + dataType
        var infoInput = SMCKeyData()
        infoInput.key = keyCode
        infoInput.data8 = SMCReader.cmdReadKeyInfo
        var infoOutput = SMCKeyData()
        guard callSMC(input: &infoInput, output: &infoOutput) else { return nil }

        let dataType = infoOutput.keyInfo.dataType
        let dataSize = infoOutput.keyInfo.dataSize

        // c. only the two temperature encodings we know how to decode are handled:
        //    - sp78: Intel SMC fixed-point
        //    - flt:  Apple Silicon SMC 32-bit float
        // Note: the SMC float type is the four characters "flt " — the trailing
        // space is load-bearing. fourCC("flt") (3 chars) would never match.
        let isSP78 = dataType == fourCC("sp78")
        let isFloat = dataType == fourCC("flt ") && dataSize == 4
        guard isSP78 || isFloat else { return nil }

        // b. ReadBytes
        var readInput = SMCKeyData()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = dataSize
        readInput.data8 = SMCReader.cmdReadBytes
        var readOutput = SMCKeyData()
        guard callSMC(input: &readInput, output: &readOutput) else { return nil }

        let b = readOutput.bytes
        let temp: Double
        if isSP78 {
            // sp78: signed fixed point, 8 integer bits + 8 fractional bits, big-endian
            temp = Double((UInt16(b.0) << 8) | UInt16(b.1)) / 256.0
        } else {
            // flt: little-endian IEEE-754 32-bit float (Apple Silicon)
            let bits = UInt32(b.0) | (UInt32(b.1) << 8) | (UInt32(b.2) << 16) | (UInt32(b.3) << 24)
            temp = Double(Float(bitPattern: bits))
        }

        // d. sanity guard
        guard temp > 0 && temp < 150 else { return nil }
        return temp
    }

    private func callSMC(input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, SMCReader.kernelIndexSMC,
                                               &input, inputSize,
                                               &output, &outputSize)
        return result == kIOReturnSuccess && output.result == 0
    }

    private func fourCC(_ str: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in str.utf8.prefix(4) {
            code = (code << 8) | UInt32(byte)
        }
        return code
    }
}
