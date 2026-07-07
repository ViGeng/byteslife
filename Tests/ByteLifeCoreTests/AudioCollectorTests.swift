import XCTest
@testable import ByteLifeCore

/// Drives the audio collector with a scripted volume reader and direct device-switch calls, so the epsilon
/// volume counting, the switch counting, and the honest degradation are verified without any hardware.
final class AudioCollectorTests: XCTestCase {
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

    func testVolumeChangesCountedBeyondEpsilon() throws {
        var volume: Double? = 0.50
        let collector = AudioCollector(
            store: store,
            epsilon: 0.01,
            now: { self.timestamp },
            readOutputVolume: { volume }
        )
        collector.poll()                     // baseline
        volume = 0.505; collector.poll()     // within jitter: no change
        volume = 0.52;  collector.poll()     // past epsilon: one change
        volume = 0.52;  collector.poll()     // unchanged
        volume = 0.30;  collector.poll()     // past epsilon: another change

        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.volumeChanges], 2)
        XCTAssertEqual(collector.availability, .running)
    }

    func testDeviceSwitchesCounted() throws {
        let collector = AudioCollector(store: store, now: { self.timestamp }, readOutputVolume: { 0.5 })
        collector.handleDeviceSwitch()
        collector.handleDeviceSwitch()
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.audioDeviceSwitches], 2)
    }

    func testNoVolumeDegradesToSourceMissing() throws {
        let collector = AudioCollector(store: store, now: { self.timestamp }, readOutputVolume: { nil })
        collector.poll()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.volumeChanges], nil)
    }
}
