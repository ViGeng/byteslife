import XCTest
@testable import ByteLifeCore

/// Shape-only smoke tests. sysctl and IOKit statistics need no TCC grant, so on a real machine they
/// return live data: at least one interface, at least one disk driver with positive counters, and a
/// non-negative idle reading.
final class SystemReadersTests: XCTestCase {

    func testNetworkReaderReturnsNamedInterfaces() {
        let interfaces = NetworkInterfaces.read()
        XCTAssertFalse(interfaces.isEmpty, "expected at least one non-loopback interface")
        XCTAssertTrue(interfaces.allSatisfy { !$0.name.isEmpty }, "every interface should have a name")
    }

    func testDiskReaderReturnsDriverWithPositiveCounters() {
        let disks = DiskStatistics.read()
        XCTAssertFalse(disks.isEmpty, "expected at least one block-storage driver")
        // Driver IDs are deduplicated, so each must be distinct.
        XCTAssertEqual(disks.count, Set(disks.map(\.driverID)).count)
        // The boot disk has certainly performed I/O since boot.
        XCTAssertTrue(disks.contains { $0.bytesRead > 0 || $0.bytesWritten > 0 })
    }

    func testIdleSecondsIsNonNegative() {
        XCTAssertGreaterThanOrEqual(IdleTime.idleSeconds(), 0)
    }
}
