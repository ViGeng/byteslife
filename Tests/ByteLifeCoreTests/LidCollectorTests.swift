import XCTest
@testable import ByteLifeCore

/// Drives the lid collector with scripted clamshell states and angles, so the open-transition counter, the
/// per-minute angle gauge, and the honest degradation are verified without any hardware.
final class LidCollectorTests: XCTestCase {
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

    func testCountsOnlyClosedToOpenTransitions() throws {
        var closed: Bool? = true
        let collector = LidCollector(
            store: store,
            now: { self.timestamp },
            readClamshellClosed: { closed },
            readLidAngle: { nil }
        )
        collector.poll()                       // baseline: closed, no count
        closed = false; collector.poll()       // closed -> open: one lid open
        closed = false; collector.poll()        // still open: no count
        closed = true;  collector.poll()        // open -> closed: no count
        closed = false; collector.poll()        // closed -> open: another lid open

        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.lidOpens], 2)
        XCTAssertEqual(collector.availability, .running)
    }

    func testAngleGaugeRecordedWhenSensorReadsAndSkippedWhenAbsent() throws {
        let withAngle = LidCollector(
            store: store,
            now: { self.timestamp },
            readClamshellClosed: { false },
            readLidAngle: { 95.4 }
        )
        withAngle.poll()
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.lidAngle, dayEpoch: dayEpoch)[10], 95)

        // A second store proves that an absent angle sensor writes no gauge while the counter still works.
        let (other, otherDir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let noAngle = LidCollector(
            store: other,
            now: { self.timestamp },
            readClamshellClosed: { false },
            readLidAngle: { nil }
        )
        noAngle.poll()
        XCTAssertEqual(try other.gaugeSeries(gauge: GaugeName.lidAngle, dayEpoch: dayEpoch)[10], nil)
        XCTAssertEqual(noAngle.availability, .running)
    }

    func testAbsentClamshellDegradesToSourceMissing() throws {
        let collector = LidCollector(
            store: store,
            now: { self.timestamp },
            readClamshellClosed: { nil },       // a desktop with no lid
            readLidAngle: { nil }
        )
        collector.poll()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.lidOpens], nil)
    }
}
