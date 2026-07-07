import XCTest
@testable import ByteLifeCore

/// Drives the battery collector with scripted readings, so the charge gauge, the charging-session edge, the
/// cycle-count fact, and the honest degradation are verified without any hardware.
final class BatteryCollectorTests: XCTestCase {
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

    func testChargeGaugeAndCycleCountFact() throws {
        let collector = BatteryCollector(
            store: store,
            now: { self.timestamp },
            readBattery: { BatteryReading(chargePercent: 84.6, isCharging: false, cycleCount: 137) }
        )
        collector.tick()
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.batteryCharge, dayEpoch: dayEpoch)[10], 85)
        XCTAssertEqual(try store.metaInt(BatteryCollector.cycleCountKey), 137)
        XCTAssertEqual(collector.availability, .running)
    }

    func testChargingSessionsCountedOnTheChargingEdge() throws {
        var reading = BatteryReading(chargePercent: 50, isCharging: false, cycleCount: nil)
        let collector = BatteryCollector(
            store: store,
            now: { self.timestamp },
            readBattery: { reading }
        )
        let key = BatteryCollector.chargingSessionsKey(dayEpoch: dayEpoch)

        collector.tick()                                                                   // baseline: idle
        XCTAssertEqual(try store.metaInt(key), nil)
        reading = BatteryReading(chargePercent: 51, isCharging: true, cycleCount: nil)
        collector.tick()                                                                   // idle -> charging
        XCTAssertEqual(try store.metaInt(key), 1)
        collector.tick()                                                                   // still charging
        XCTAssertEqual(try store.metaInt(key), 1)
        reading = BatteryReading(chargePercent: 90, isCharging: false, cycleCount: nil)
        collector.tick()                                                                   // unplugged
        reading = BatteryReading(chargePercent: 91, isCharging: true, cycleCount: nil)
        collector.tick()                                                                   // charging again
        XCTAssertEqual(try store.metaInt(key), 2)
    }

    func testNoBatteryDegradesToSourceMissing() throws {
        let collector = BatteryCollector(
            store: store,
            now: { self.timestamp },
            readBattery: { nil }                 // a desktop with no battery
        )
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.batteryCharge, dayEpoch: dayEpoch)[10], nil)
    }
}
