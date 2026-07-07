import XCTest
@testable import ByteLifeCore

/// Drives the Bluetooth collector with a scripted connected-count reader, so connect events are counted as
/// the rise in the count (never a disconnect) and the degradation is honest, all without any hardware.
final class BluetoothCollectorTests: XCTestCase {
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

    func testConnectsCountedAsTheRiseInConnectedCount() throws {
        var count: Int? = 1
        let collector = BluetoothCollector(
            store: store,
            now: { self.timestamp },
            readConnectedCount: { count }
        )
        collector.tick()               // baseline at one
        count = 3; collector.tick()    // +2 connects
        count = 2; collector.tick()    // a disconnect: no connect booked
        count = 5; collector.tick()    // +3 connects

        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.btConnects], 5)
        XCTAssertEqual(collector.availability, .running)
    }

    func testUnavailableBluetoothDegradesToSourceMissing() throws {
        let collector = BluetoothCollector(
            store: store,
            now: { self.timestamp },
            readConnectedCount: { nil }
        )
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.btConnects], nil)
    }
}
