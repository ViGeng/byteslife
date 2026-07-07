import Foundation
import IOKit

/// A source of SMC sensor readings, one decoded double per key. Injectable so the collectors and the
/// power reader are driven deterministically in tests while production talks to real hardware.
public protocol SMCReading {
    /// The decoded value for a four-character SMC key, or nil when the key is absent, the connection is
    /// closed, or the data type is not one this reader decodes.
    func read(key: String) -> Double?
}

/// Pure SMC key and value codecs, factored out of the IOKit path so they are tested against fixture byte
/// patterns without any hardware. FourCC keys pack four ASCII bytes into a big-endian UInt32. Values
/// arrive as raw bytes tagged with a four-character data type; only the types the sensors need are
/// decoded here: `flt ` (little-endian IEEE-754 float), `fpe2` (big-endian unsigned fixed point, two
/// fractional bits), and `sp78` (big-endian signed fixed point, eight fractional bits).
enum SMCDecoding {
    /// Packs up to four ASCII bytes of `key` into a big-endian UInt32, the SMC key encoding.
    static func fourCC(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    /// The four-character string a packed key or data-type code represents, unpacking the big-endian bytes.
    static func fourCCString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Decodes `bytes` as the given SMC `dataType`. Returns nil for an unknown type or a buffer too short
    /// for it, so an unreadable key degrades honestly rather than inventing a number.
    static func decode(bytes: [UInt8], dataType: String) -> Double? {
        switch dataType {
        case "flt ":
            // 32-bit IEEE-754, little-endian on the wire.
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "fpe2":
            // Unsigned 14.2 fixed point, big-endian: value = raw / 4. Fan RPM keys use this.
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "sp78":
            // Signed 7.8 fixed point, big-endian: value = raw / 256. Temperature keys use this.
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        default:
            return nil
        }
    }
}

/// Talks to the AppleSMC user client to read sensor keys with no privileges, the same technique the
/// open-source Stats app uses. Opening `AppleSMC` and issuing the two-struct call (get key info, then
/// read the bytes) needs no entitlement or TCC grant. The wire protocol lives here; the pure key/value
/// codecs live in `SMCDecoding` so the decoding is tested without hardware. A single shared instance
/// holds the connection open for the app's lifetime; when the service is absent (unusual, but possible
/// in a VM) every read returns nil and the caller degrades to its fallback.
public final class SMCReader: SMCReading, @unchecked Sendable {
    /// The process-wide reader, opened lazily on first use. Production code reads through this; tests
    /// inject their own `SMCReading` and never touch it, so no IOKit connection opens under `swift test`.
    public static let shared = SMCReader()

    private var connection: io_connect_t = 0
    private let opened: Bool

    /// Opens the AppleSMC user client. Leaves `opened` false when the service is missing or the open
    /// fails, in which case every read returns nil.
    public init() {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { opened = false; return }
        defer { IOObjectRelease(device) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            opened = false
            return
        }
        connection = conn
        opened = true
    }

    deinit {
        if opened { IOServiceClose(connection) }
    }

    /// Reads one key: first a key-info call resolves the data size and type, then a read call pulls the
    /// bytes, which the pure decoder turns into a double. Any failed call, a nonzero SMC result, or an
    /// undecodable type yields nil.
    public func read(key: String) -> Double? {
        guard opened else { return nil }
        let code = SMCDecoding.fourCC(key)

        var infoInput = SMCKeyData()
        infoInput.key = code
        infoInput.data8 = SMCReader.getKeyInfo
        guard let info = call(&infoInput), info.result == 0 else { return nil }
        let dataSize = info.keyInfo.dataSize
        let dataType = info.keyInfo.dataType
        guard dataSize > 0 else { return nil }

        var readInput = SMCKeyData()
        readInput.key = code
        readInput.keyInfo.dataSize = dataSize
        readInput.data8 = SMCReader.readKey
        guard let output = call(&readInput), output.result == 0 else { return nil }

        let type = SMCDecoding.fourCCString(dataType)
        let bytes = SMCReader.bytesToArray(output.bytes, count: Int(dataSize))
        return SMCDecoding.decode(bytes: bytes, dataType: type)
    }

    /// Issues one structured method call against the SMC user client, returning the output struct or nil
    /// on a kernel error.
    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection, SMCReader.kernelIndex, &input, inputSize, &output, &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        return output
    }

    /// Copies the fixed 32-byte SMC payload tuple into a `[UInt8]` truncated to the key's actual size.
    private static func bytesToArray(_ bytes: SMCPayload, count: Int) -> [UInt8] {
        var mutable = bytes
        return withUnsafeBytes(of: &mutable) { raw in
            Array(raw.prefix(min(max(count, 0), 32)))
        }
    }

    // The SMC user-client method selector and the two data-command codes.
    private static let kernelIndex: UInt32 = 2   // KERNEL_INDEX_SMC
    private static let readKey: UInt8 = 5        // kSMCReadKey
    private static let getKeyInfo: UInt8 = 9     // kSMCGetKeyInfo
}

/// System power in milliwatts, preferring the SMC total-power key and falling back to the battery reader.
///
/// The SMC key `PSTR` reports whole-system power in watts as a float, which is present on AC as well as
/// on battery, so it is the honest energy signal the Energy Account wants. When SMC has no such reading
/// (a machine or VM without the key), the battery amperage×voltage path stands in, and when neither has a
/// signal the value is nil so the collector degrades to `sourceMissing`.
public enum SystemPower {
    /// Instantaneous system power in milliwatts, or nil when neither source reports one. A non-positive
    /// SMC reading is treated as no signal and falls through to the battery path.
    public static func milliwatts(
        smc: SMCReading = SMCReader.shared,
        battery: () -> Double? = PowerSource.milliwatts
    ) -> Double? {
        if let watts = smc.read(key: "PSTR"), watts > 0 {
            return watts * 1_000.0
        }
        return battery()
    }
}

// MARK: - AppleSMC wire structs

/// The fixed 32-byte SMC value payload. Declared as a tuple so the enclosing struct keeps the exact C
/// layout `IOConnectCallStructMethod` expects.
private typealias SMCPayload = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // The C `SMCKeyInfoData` is padded to a 12-byte, 4-byte-aligned struct. Swift would otherwise pack
    // this to 9 bytes, shrinking the enclosing `SMCKeyData` to 76 bytes and shifting `data32`/`bytes`, so
    // the AppleSMC call is rejected with kIOReturnBadArgument. The explicit padding restores the exact
    // 80-byte layout the kernel expects.
    var reserved0: UInt8 = 0
    var reserved1: UInt8 = 0
    var reserved2: UInt8 = 0
}

/// The `SMCKeyData_t` request/response struct exchanged with the AppleSMC user client. Field order and
/// types mirror the C definition the Stats/SMCKit projects use so the memory layout matches on the wire.
private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCPayload = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
