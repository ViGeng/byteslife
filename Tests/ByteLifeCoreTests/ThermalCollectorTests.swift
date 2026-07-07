import XCTest
@testable import ByteLifeCore

/// Drives the thermal collector with scripted SMC readers and thermal-state levels, so the curve units,
/// the independent gauges, and the change memo are verified without any hardware.
final class ThermalCollectorTests: XCTestCase {
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

    func testGaugesRecordedInTheirUnits() throws {
        let collector = ThermalCollector(
            store: store,
            now: { self.timestamp },
            readTemperatureCelsius: { 45.6 },   // deci-degrees: 456
            readFanRPM: { 2100 },
            readMilliwatts: { 12_340 },          // 12.34 W -> 123 deci-watts
            readThermalState: { 0 }
        )
        collector.tick()
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.cpuTemperature, dayEpoch: dayEpoch)[10], 456)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.fanRPM, dayEpoch: dayEpoch)[10], 2100)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.systemPowerWatts, dayEpoch: dayEpoch)[10], 123)
        XCTAssertEqual(collector.availability, .running)
    }

    func testMissingTemperatureDegradesButFanStillBooks() throws {
        let collector = ThermalCollector(
            store: store,
            now: { self.timestamp },
            readTemperatureCelsius: { nil },     // no accessible SMC temperature
            readFanRPM: { 1800 },
            readMilliwatts: { nil },
            readThermalState: { 0 }
        )
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.cpuTemperature, dayEpoch: dayEpoch)[10], nil)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.fanRPM, dayEpoch: dayEpoch)[10], 1800)
    }

    func testThermalStateChangesCountedIntoDayMeta() throws {
        var level = 0
        let collector = ThermalCollector(
            store: store,
            now: { self.timestamp },
            readTemperatureCelsius: { nil },
            readFanRPM: { nil },
            readMilliwatts: { nil },
            readThermalState: { level }
        )
        let key = ThermalCollector.thermalChangesKey(dayEpoch: dayEpoch)

        collector.recordThermalStateIfChanged()               // baseline at nominal, no change
        XCTAssertEqual(try store.metaInt(key), nil)
        level = 2; collector.recordThermalStateIfChanged()    // nominal -> serious
        XCTAssertEqual(try store.metaInt(key), 1)
        level = 2; collector.recordThermalStateIfChanged()    // unchanged
        XCTAssertEqual(try store.metaInt(key), 1)
        level = 0; collector.recordThermalStateIfChanged()    // serious -> nominal
        XCTAssertEqual(try store.metaInt(key), 2)
    }
}
