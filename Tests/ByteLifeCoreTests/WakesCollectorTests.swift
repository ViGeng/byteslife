import XCTest
@testable import ByteLifeCore

/// Drives the wakes collector with a scripted boot-time reader and direct wake calls, so wake counting and
/// boot detection are verified without any hardware.
final class WakesCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private var timestamp: Date!
    private var dayEpoch: Int64!

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
        timestamp = fixedTimestamp(minute: 10)
        dayEpoch = DayBucket.dayEpoch(for: timestamp)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testWakesCounted() throws {
        let collector = WakesCollector(store: store, now: { self.timestamp }, readBootTime: { 1000 })
        collector.handleWake()
        collector.handleWake()
        collector.handleWake()
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.systemWakes], 3)
    }

    func testBootBookedOnlyWhenBootTimeChanges() throws {
        var bootTime: Int64? = 1000
        let collector = WakesCollector(store: store, now: { self.timestamp }, readBootTime: { bootTime })

        collector.checkBoot()                                            // first launch: baseline only
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.systemBoots], nil)
        XCTAssertEqual(try store.metaInt(WakesCollector.bootTimeKey), 1000)

        collector.checkBoot()                                            // relaunch, same boot: no count
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.systemBoots], nil)

        bootTime = 2000; collector.checkBoot()                          // rebooted since: one boot
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.systemBoots], 1)
        XCTAssertEqual(try store.metaInt(WakesCollector.bootTimeKey), 2000)

        collector.checkBoot()                                            // same boot again: no further count
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.systemBoots], 1)
    }

    func testUnreadableBootTimeIsANoOp() throws {
        let collector = WakesCollector(store: store, now: { self.timestamp }, readBootTime: { nil })
        collector.checkBoot()
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.systemBoots], nil)
        XCTAssertEqual(try store.metaInt(WakesCollector.bootTimeKey), nil)
    }
}
