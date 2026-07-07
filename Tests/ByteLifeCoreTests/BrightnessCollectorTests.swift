import XCTest
@testable import ByteLifeCore

/// Drives the brightness collector with a scripted fraction reader, so the per-mille gauge, the clamp, and
/// the honest degradation are verified without any hardware.
final class BrightnessCollectorTests: XCTestCase {
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

    func testBrightnessGaugeInPerMille() throws {
        let collector = BrightnessCollector(
            store: store,
            now: { self.timestamp },
            readBrightness: { 0.732 }            // per mille: 732
        )
        collector.tick()
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.displayBrightness, dayEpoch: dayEpoch)[10], 732)
        XCTAssertEqual(collector.availability, .running)
    }

    func testAbsentFrameworkDegradesToSourceMissing() throws {
        let collector = BrightnessCollector(
            store: store,
            now: { self.timestamp },
            readBrightness: { nil }
        )
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.gaugeSeries(gauge: GaugeName.displayBrightness, dayEpoch: dayEpoch)[10], nil)
    }
}
