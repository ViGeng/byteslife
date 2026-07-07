import XCTest
@testable import ByteLifeCore

/// Drives the ambient-light collector with a scripted lux reader, so the per-minute gauge and the honest
/// degradation are verified without any hardware.
final class AmbientLightCollectorTests: XCTestCase {
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

    func testLuxGaugeRecorded() throws {
        let collector = AmbientLightCollector(
            store: store,
            now: { self.timestamp },
            readLux: { 342.7 }
        )
        collector.tick()
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.ambientLux, dayEpoch: dayEpoch)[10], 343)
        XCTAssertEqual(collector.availability, .running)
    }

    func testAbsentSensorDegradesToSourceMissing() throws {
        let collector = AmbientLightCollector(
            store: store,
            now: { self.timestamp },
            readLux: { nil }
        )
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.ambientLux, dayEpoch: dayEpoch)[10], nil)
    }
}
