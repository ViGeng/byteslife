import Foundation
import IOKit

/// Cumulative since-boot byte counters for one physical block-storage driver.
public struct DiskCounters: Equatable, Sendable {
    /// The driver's IORegistry entry ID. Stable per physical device and shared by all APFS
    /// partitions on it, which is why callers deduplicate on this value.
    public let driverID: UInt64
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public init(driverID: UInt64, bytesRead: UInt64, bytesWritten: UInt64) {
        self.driverID = driverID
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

/// Reads per-physical-disk cumulative bytes read/written from IOKit's `IOBlockStorageDriver`
/// Statistics dictionaries. Each `IOMedia` node is walked up to its owning driver; drivers are
/// deduplicated by registry entry ID because the APFS partitions of one disk share a single driver.
public enum DiskStatistics {
    /// One `DiskCounters` per physical block-storage driver. Empty on matching failure.
    ///
    /// Every `io_object_t` obtained here is released exactly once, including on early-exit paths.
    public static func read() -> [DiskCounters] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOMedia")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var byDriverID: [UInt64: DiskCounters] = [:]
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }

            guard let driver = blockStorageDriver(startingFrom: media) else { continue }
            defer { IOObjectRelease(driver) }

            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &entryID) == KERN_SUCCESS else { continue }
            // APFS partitions share one driver, so the first sighting of an ID wins and the rest are skipped.
            guard byDriverID[entryID] == nil, let stats = statistics(of: driver) else { continue }
            byDriverID[entryID] = DiskCounters(
                driverID: entryID,
                bytesRead: stats.read,
                bytesWritten: stats.written
            )
        }
        return Array(byDriverID.values)
    }

    /// Walks parents from `media` until an `IOBlockStorageDriver` is found. Returns a `+1` reference
    /// the caller must release, or nil. `media` itself stays owned by the caller (never released here),
    /// so an early match on `media` is retained to keep the "caller releases the result" contract.
    private static func blockStorageDriver(startingFrom media: io_object_t) -> io_object_t? {
        if IOObjectConformsTo(media, "IOBlockStorageDriver") != 0 {
            IOObjectRetain(media)
            return media
        }
        var current = media
        var ownsCurrent = false // true once `current` is a parent we hold a +1 reference on
        while true {
            var parent: io_registry_entry_t = 0
            let rc = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if ownsCurrent { IOObjectRelease(current) }
            guard rc == KERN_SUCCESS, parent != 0 else { return nil }
            current = parent
            ownsCurrent = true
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 {
                return current // already +1 from IORegistryEntryGetParentEntry
            }
        }
    }

    private static func statistics(of driver: io_object_t) -> (read: UInt64, written: UInt64)? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(driver, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let stats = dictionary["Statistics"] as? [String: Any] else {
            return nil
        }
        let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let written = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        return (read, written)
    }
}
