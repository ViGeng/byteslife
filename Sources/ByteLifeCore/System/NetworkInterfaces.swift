import Foundation

/// Cumulative since-boot byte counters for one network interface.
public struct InterfaceCounters: Equatable, Sendable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Reads 64-bit per-interface byte counters via `sysctl(NET_RT_IFLIST2)`, walking the returned buffer
/// over `if_msghdr2` records and pulling `ifi_ibytes`/`ifi_obytes` from each record's embedded
/// `if_data64`. This is a plain BSD call needing no entitlement or TCC grant.
public enum NetworkInterfaces {
    /// One `InterfaceCounters` per non-loopback interface. Empty on any sysctl failure.
    public static func read() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        // First call sizes the buffer; the second fills it.
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: needed)
        let rc = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &needed, nil, 0)
        }
        guard rc == 0 else { return [] }

        var result: [InterfaceCounters] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let headerSize = MemoryLayout<if_msghdr>.size
            let msg2Size = MemoryLayout<if_msghdr2>.size
            var offset = 0
            // Records are variable length; each header's ifm_msglen advances the cursor. Structs are
            // copied out with memcpy because records sit at arbitrary offsets and a direct load would
            // be misaligned.
            while offset + headerSize <= needed {
                var header = if_msghdr()
                memcpy(&header, base + offset, headerSize)
                let msglen = Int(header.ifm_msglen)
                guard msglen > 0 else { break }

                if header.ifm_type == UInt8(RTM_IFINFO2), offset + msg2Size <= needed {
                    var msg = if_msghdr2()
                    memcpy(&msg, base + offset, msg2Size)
                    if msg.ifm_data.ifi_type != UInt8(IFT_LOOP) {
                        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                        if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil {
                            result.append(InterfaceCounters(
                                name: String(cString: nameBuffer),
                                bytesIn: msg.ifm_data.ifi_ibytes,
                                bytesOut: msg.ifm_data.ifi_obytes
                            ))
                        }
                    }
                }
                offset += msglen
            }
        }
        return result
    }
}
