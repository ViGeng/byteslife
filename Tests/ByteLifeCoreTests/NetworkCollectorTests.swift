import XCTest
@testable import ByteLifeCore

final class NetworkCollectorTests: XCTestCase {
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
            [InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 2_000)],
            [InterfaceCounters(name: "en0", bytesIn: 1_500, bytesOut: 2_600)],
        ])
        let collector = NetworkCollector(store: store, read: reader.next)

        collector.poll(now: timestamp)
        XCTAssertTrue(try store.totals(forDayEpoch: dayEpoch).isEmpty, "first poll only baselines")

        collector.poll(now: timestamp)
        let totals = try store.totals(forDayEpoch: dayEpoch)
        XCTAssertEqual(totals[.networkBytesIn], 500)
        XCTAssertEqual(totals[.networkBytesOut], 600)
    }

    func testCounterDecreaseRebaselinesWithoutEmitting() throws {
        let reader = ScriptedReader([
            [InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 1_000)],
            [InterfaceCounters(name: "en0", bytesIn: 400, bytesOut: 1_000)],   // in dropped: reset
            [InterfaceCounters(name: "en0", bytesIn: 700, bytesOut: 1_000)],   // +300 from new baseline
        ])
        let collector = NetworkCollector(store: store, read: reader.next)

        collector.poll(now: timestamp) // baseline
        collector.poll(now: timestamp) // reset: no emission
        XCTAssertTrue(try store.totals(forDayEpoch: dayEpoch).isEmpty)

        collector.poll(now: timestamp) // +300 from the re-baselined 400
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.networkBytesIn], 300)
    }

    func testPerInterfaceIndependenceWhenOneVanishes() throws {
        let reader = ScriptedReader([
            [InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 0),
             InterfaceCounters(name: "utun0", bytesIn: 5_000, bytesOut: 0)],
            // utun0 disappears (VPN down); en0 keeps counting from its own baseline.
            [InterfaceCounters(name: "en0", bytesIn: 1_400, bytesOut: 0)],
        ])
        let collector = NetworkCollector(store: store, read: reader.next)

        collector.poll(now: timestamp)
        collector.poll(now: timestamp)
        // Only en0's +400 registers; the vanished utun0 must not read as a reset or a spurious delta.
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.networkBytesIn], 400)
    }

    func testBaselinePersistsAcrossSimulatedRestart() throws {
        let readerA = ScriptedReader([
            [InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 0)],
            [InterfaceCounters(name: "en0", bytesIn: 1_500, bytesOut: 0)],
        ])
        let collectorA = NetworkCollector(store: store, read: readerA.next)
        collectorA.poll(now: timestamp) // baseline 1000
        collectorA.poll(now: timestamp) // +500

        // A fresh collector on the same store resumes from the persisted 1500 baseline, not from scratch.
        let readerB = ScriptedReader([[InterfaceCounters(name: "en0", bytesIn: 2_000, bytesOut: 0)]])
        let collectorB = NetworkCollector(store: store, read: readerB.next)
        collectorB.poll(now: timestamp) // +500 from the persisted baseline

        // 500 + 500. Had the baseline reset on restart, this poll would emit 0 and the total stay 500.
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.networkBytesIn], 1_000)
    }

    func testBaselineHoldsWhenWriteFailsSoDeltaReemitsInFull() throws {
        let spy = SpyCounterStore()
        let reader = ScriptedReader([
            [InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 0)],
            [InterfaceCounters(name: "en0", bytesIn: 1_500, bytesOut: 0)], // +500, but the write fails
            [InterfaceCounters(name: "en0", bytesIn: 1_800, bytesOut: 0)], // write succeeds again
        ])
        let collector = NetworkCollector(store: spy, read: reader.next)

        collector.poll(now: timestamp) // baseline 1000

        spy.shouldFail = true
        collector.poll(now: timestamp) // computes +500, write throws, baseline must not advance
        spy.shouldFail = false

        collector.poll(now: timestamp)
        // The baseline stayed at 1000, so this emits the full 800 (1800 - 1000), reclaiming the lost
        // interval. Had it advanced to 1500 on the failed write, this would emit only 300 and lose 500.
        XCTAssertEqual(spy.lastRecorded.first(where: { $0.kind == .networkBytesIn })?.value, 800)
    }
}
