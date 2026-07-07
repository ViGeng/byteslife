import XCTest
@testable import ByteLifeCore

/// Drives the energy accrual with an injected monotonic clock and power reader, so integration and the
/// sub-unit carry are deterministic, plus the honest degradation when no wattage signal exists.
final class EnergyCollectorTests: XCTestCase {
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

    private func total() throws -> Int64 {
        try store.totals(forDayEpoch: dayEpoch)[.energyMilliwattHours] ?? 0
    }

    func testAccumulatorIntegratesPowerOverTimeWithCarry() {
        // 100 mW held for 60 s = 100 * 60 / 3600 = 1.667 mWh: emit 1, carry ~0.667.
        let first = EnergyAccumulator.accumulate(powerMilliwatts: 100, elapsedSeconds: 60, carried: 0)
        XCTAssertEqual(first.emit, 1)
        XCTAssertEqual(first.carry, 100 * 60 / 3600 - 1, accuracy: 1e-9)

        // The carry rolls into the next step so nothing is lost: 0.667 carried + 1.667 accrued = 2.333,
        // which books 2 whole mWh. Across the two ticks that is 3 mWh, the floor of 100 mW over 120 s.
        let second = EnergyAccumulator.accumulate(powerMilliwatts: 100, elapsedSeconds: 60, carried: first.carry)
        XCTAssertEqual(second.emit, 2)
        XCTAssertEqual(first.emit + second.emit, 3)

        // Non-positive inputs preserve the carry and emit nothing.
        XCTAssertEqual(EnergyAccumulator.accumulate(powerMilliwatts: 0, elapsedSeconds: 60, carried: 0.4).emit, 0)
        XCTAssertEqual(EnergyAccumulator.accumulate(powerMilliwatts: 5, elapsedSeconds: 0, carried: 0.4).carry, 0.4)
    }

    func testCollectorBooksMilliwattHoursFromWattageOverElapsedTime() throws {
        var nanos: UInt64 = 0
        let collector = EnergyCollector(
            store: store,
            readMilliwatts: { 5_000 },       // a steady 5 W draw
            clock: { nanos },
            now: { self.timestamp }
        )

        nanos = 0
        collector.tick()                     // baseline, no elapsed time yet
        XCTAssertEqual(try total(), 0)

        nanos = 3_600_000_000_000            // +3600 s = 1 h
        collector.tick()                     // 5000 mW * 1 h = 5000 mWh
        XCTAssertEqual(try total(), 5_000)
        XCTAssertEqual(collector.availability, .running)
    }

    func testNilWattageSignalDegradesToSourceMissingAndBooksNothing() throws {
        var nanos: UInt64 = 0
        let collector = EnergyCollector(
            store: store,
            readMilliwatts: { nil },         // a desktop with no battery
            clock: { nanos },
            now: { self.timestamp }
        )
        nanos = 3_600_000_000_000
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try total(), 0)
    }
}
