import XCTest
@testable import ByteLifeCore

final class DiskCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private var timestamp: Date!
    private var dayEpoch: Int64!

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
        timestamp = fixedTimestamp()
        dayEpoch = DayBucket.dayEpoch(for: timestamp)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testFirstPollBaselinesSilentlyThenSecondEmitsDeltas() throws {
        let reader = ScriptedReader([
            [DiskCounters(driverID: 1, bytesRead: 10_000, bytesWritten: 20_000)],
            [DiskCounters(driverID: 1, bytesRead: 12_000, bytesWritten: 20_500)],
        ])
        let collector = DiskCollector(store: store, read: reader.next)

        collector.poll(now: timestamp)
        XCTAssertTrue(try store.totals(forDayEpoch: dayEpoch).isEmpty, "first poll only baselines")

        collector.poll(now: timestamp)
        let totals = try store.totals(forDayEpoch: dayEpoch)
        XCTAssertEqual(totals[.diskBytesRead], 2_000)
        XCTAssertEqual(totals[.diskBytesWritten], 500)
    }

    func testCounterDecreaseRebaselinesWithoutEmitting() throws {
        let reader = ScriptedReader([
            [DiskCounters(driverID: 1, bytesRead: 10_000, bytesWritten: 0)],
            [DiskCounters(driverID: 1, bytesRead: 3_000, bytesWritten: 0)], // reboot: counter dropped
            [DiskCounters(driverID: 1, bytesRead: 5_000, bytesWritten: 0)], // +2000 from new baseline
        ])
        let collector = DiskCollector(store: store, read: reader.next)

        collector.poll(now: timestamp)
        collector.poll(now: timestamp)
        XCTAssertTrue(try store.totals(forDayEpoch: dayEpoch).isEmpty)

        collector.poll(now: timestamp)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.diskBytesRead], 2_000)
    }

    func testPerDriverIndependenceWhenOneVanishes() throws {
        let reader = ScriptedReader([
            [DiskCounters(driverID: 1, bytesRead: 10_000, bytesWritten: 0),
             DiskCounters(driverID: 2, bytesRead: 90_000, bytesWritten: 0)],
            // Driver 2 (an unplugged external) disappears; driver 1 keeps its own baseline.
            [DiskCounters(driverID: 1, bytesRead: 13_000, bytesWritten: 0)],
        ])
        let collector = DiskCollector(store: store, read: reader.next)

        collector.poll(now: timestamp)
        collector.poll(now: timestamp)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.diskBytesRead], 3_000)
    }

    func testBaselinePersistsAcrossSimulatedRestart() throws {
        let readerA = ScriptedReader([
            [DiskCounters(driverID: 1, bytesRead: 10_000, bytesWritten: 0)],
            [DiskCounters(driverID: 1, bytesRead: 11_000, bytesWritten: 0)],
        ])
        let collectorA = DiskCollector(store: store, read: readerA.next)
        collectorA.poll(now: timestamp) // baseline
        collectorA.poll(now: timestamp) // +1000

        let readerB = ScriptedReader([[DiskCounters(driverID: 1, bytesRead: 12_000, bytesWritten: 0)]])
        let collectorB = DiskCollector(store: store, read: readerB.next)
        collectorB.poll(now: timestamp) // +1000 from the persisted 11000 baseline

        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.diskBytesRead], 2_000)
    }

    func testBaselineHoldsWhenWriteFailsSoDeltaReemitsInFull() throws {
        let spy = SpyCounterStore()
        let reader = ScriptedReader([
            [DiskCounters(driverID: 1, bytesRead: 10_000, bytesWritten: 0)],
            [DiskCounters(driverID: 1, bytesRead: 12_000, bytesWritten: 0)], // +2000, but the write fails
            [DiskCounters(driverID: 1, bytesRead: 13_000, bytesWritten: 0)], // write succeeds again
        ])
        let collector = DiskCollector(store: spy, read: reader.next)

        collector.poll(now: timestamp) // baseline 10000

        spy.shouldFail = true
        collector.poll(now: timestamp) // computes +2000, write throws, baseline must not advance
        spy.shouldFail = false

        collector.poll(now: timestamp)
        // The baseline stayed at 10000, so this emits the full 3000 (13000 - 10000), reclaiming the lost
        // interval. Had it advanced to 12000 on the failed write, this would emit only 1000 and lose 2000.
        XCTAssertEqual(spy.lastRecorded.first(where: { $0.kind == .diskBytesRead })?.value, 3_000)
    }
}
