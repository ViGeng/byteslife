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
            isAuthorized: { true },
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
            isAuthorized: { true },
            readConnectedCount: { nil }
        )
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.btConnects], nil)
    }

    /// The regression that crashed 0.8.0: an unauthorized process touching IOBluetooth is KILLED by
    /// tccd. The gate must fail closed — an unauthorized tick books needs-permission, never reaches the
    /// reader, and records nothing.
    func testUnauthorizedTickNeverTouchesTheReader() throws {
        var readerTouched = false
        let collector = BluetoothCollector(
            store: store,
            now: { self.timestamp },
            isAuthorized: { false },
            readConnectedCount: { readerTouched = true; return 2 }
        )
        collector.tick()
        collector.tick()
        XCTAssertFalse(readerTouched, "an unauthorized tick reached IOBluetooth — this is the TCC kill")
        XCTAssertEqual(collector.availability, .needsPermission)
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.btConnects], nil)
    }

    /// A grant arriving mid-session (the user allows in System Settings) is picked up by the next tick:
    /// the first authorized sample only baselines, and counting starts from there.
    func testGrantArrivingMidSessionStartsCountingFromABaseline() throws {
        var authorized = false
        var count: Int? = 2
        let collector = BluetoothCollector(
            store: store,
            now: { self.timestamp },
            isAuthorized: { authorized },
            readConnectedCount: { count }
        )
        collector.tick()                       // unauthorized: nothing
        authorized = true
        collector.tick()                       // baseline at two
        count = 4; collector.tick()            // +2 connects
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.btConnects], 2)
        XCTAssertEqual(collector.availability, .running)
    }
}
