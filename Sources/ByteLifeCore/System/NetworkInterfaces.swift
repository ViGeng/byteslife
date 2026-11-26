import Foundation
import CoreWLAN
import SystemConfiguration

public enum NetworkConnection: Hashable, Sendable {
    case wifi(ssid: String?)
    case ethernet
    case other
}

/// Bytes counted on one connection during a polling interval or across a recorded day.
public struct NetworkTraffic: Equatable, Identifiable, Sendable {
    public let connection: NetworkConnection
    public let bytesIn: Int64
    public let bytesOut: Int64

    public var id: NetworkConnection { connection }
}

/// Cumulative since-boot byte counters for one network interface.
public struct InterfaceCounters: Equatable, Sendable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let connection: NetworkConnection

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64, connection: NetworkConnection = .other) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.connection = connection
    }
}

/// Reads 64-bit per-interface byte counters via `sysctl(NET_RT_IFLIST2)`, walking the returned buffer
/// over `if_msghdr2` records and pulling `ifi_ibytes`/`ifi_obytes` from each record's embedded
/// `if_data64`. This is a plain BSD call needing no entitlement or TCC grant.
public enum NetworkInterfaces {
    /// One `InterfaceCounters` per non-loopback interface. Empty on any sysctl failure.
    public static func read() -> [InterfaceCounters] {
        read(includingWiFiNames: false)
    }

    /// CoreWLAN returns a name only when the system allows the app to see it. The interface type is
    /// available independently of that permission. Query the hardware list each poll for USB adapters.
    public static func read(includingWiFiNames: Bool) -> [InterfaceCounters] {
        var connections: [String: NetworkConnection] = [:]
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 {
                connections[bsdName as String] = .wifi(ssid: nil)
            } else if type == kSCNetworkInterfaceTypeEthernet {
                connections[bsdName as String] = .ethernet
            }
        }
        let wifi = CWWiFiClient.shared()
        for name in wifi.interfaceNames() ?? [] {
            let ssid = includingWiFiNames ? wifi.interface(withName: name)?.ssid() : nil
            connections[name] = .wifi(ssid: ssid.flatMap { $0.isEmpty ? nil : $0 })
        }

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
                            let name = String(cString: nameBuffer)
                            result.append(InterfaceCounters(
                                name: name,
                                bytesIn: msg.ifm_data.ifi_ibytes,
                                bytesOut: msg.ifm_data.ifi_obytes,
                                connection: connections[name] ?? .other
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
