import XCTest
import SQLite3
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

    func testBreakdownWriteFailureRollsBackAggregateAndBaseline() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("t.sqlite").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }
        let wifi = NetworkConnection.wifi(ssid: "Home")
        let reader = ScriptedReader([
            [InterfaceCounters(name: "en0", bytesIn: 1_000, bytesOut: 0, connection: wifi)],
            [InterfaceCounters(name: "en0", bytesIn: 1_500, bytesOut: 0, connection: .wifi(ssid: "Hotspot"))],
            [InterfaceCounters(name: "en0", bytesIn: 1_800, bytesOut: 0, connection: wifi)],
        ])
        let collector = NetworkCollector(store: store, read: reader.next)
        collector.poll(now: timestamp)

        try execSQL(db, """
            CREATE TRIGGER reject_network_traffic BEFORE INSERT ON network_traffic
            BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END;
            """)
        collector.poll(now: timestamp.addingTimeInterval(3))
        XCTAssertTrue(try store.totals(forDayEpoch: dayEpoch).isEmpty)
        XCTAssertTrue(try store.networkTraffic(dayEpoch: dayEpoch).isEmpty)
        XCTAssertEqual(try store.metaInt(NetworkCollector.inKey("en0")), 1_000)

        try execSQL(db, "DROP TRIGGER reject_network_traffic;")
        collector.poll(now: timestamp.addingTimeInterval(6))
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.networkBytesIn], 800)
        XCTAssertEqual(try store.networkTraffic(dayEpoch: dayEpoch), [
            NetworkTraffic(connection: .wifi(ssid: nil), bytesIn: 800, bytesOut: 0),
        ])
    }

    func testGroupsConcurrentInterfacesByConnectionAndBooksWiFiSwitchesSeparately() throws {
        let hotspot = NetworkConnection.wifi(ssid: "Wei’s iPhone")
        let router = NetworkConnection.wifi(ssid: "5G Router")
        func frame(_ wifi: NetworkConnection, _ count: UInt64) -> [InterfaceCounters] {
            [
                InterfaceCounters(name: "en0", bytesIn: count * 10, bytesOut: count * 2, connection: wifi),
                InterfaceCounters(name: "en1", bytesIn: count * 20, bytesOut: count * 3, connection: .ethernet),
                InterfaceCounters(name: "en2", bytesIn: count * 30, bytesOut: 0, connection: .ethernet),
                InterfaceCounters(name: "utun0", bytesIn: count, bytesOut: count),
            ]
        }
        let reader = ScriptedReader([frame(hotspot, 1), frame(hotspot, 2), frame(router, 3), frame(router, 4)])
        let collector = NetworkCollector(store: store, read: reader.next)
        for i in 0..<4 {
            collector.poll(now: timestamp.addingTimeInterval(TimeInterval(i * 3)))
        }

        let rows = try store.networkTraffic(dayEpoch: dayEpoch)
        XCTAssertEqual(rows, [
            NetworkTraffic(connection: .ethernet, bytesIn: 150, bytesOut: 9),
            NetworkTraffic(connection: .wifi(ssid: nil), bytesIn: 10, bytesOut: 2),
            NetworkTraffic(connection: router, bytesIn: 10, bytesOut: 2),
            NetworkTraffic(connection: hotspot, bytesIn: 10, bytesOut: 2),
            NetworkTraffic(connection: .other, bytesIn: 3, bytesOut: 3),
        ])
        let totals = try store.totals(forDayEpoch: dayEpoch)
        XCTAssertEqual(totals[.networkBytesIn], rows.reduce(0) { $0 + $1.bytesIn })
        XCTAssertEqual(totals[.networkBytesOut], rows.reduce(0) { $0 + $1.bytesOut })
    }

    func testRestartAndLongGapKeepWiFiBytesWithoutGuessingTheirName() throws {
        let wifi = NetworkConnection.wifi(ssid: "Hotspot")
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: timestamp))
        let tomorrowEpoch = DayBucket.dayEpoch(for: tomorrow)
        let reader = ScriptedReader((1...5).map {
            [InterfaceCounters(name: "en0", bytesIn: UInt64($0 * 100), bytesOut: 0, connection: wifi)]
        })
        let collector = NetworkCollector(store: store, read: reader.next)
        collector.poll(now: timestamp)
        collector.poll(now: timestamp.addingTimeInterval(3))

        let restarted = NetworkCollector(store: store, read: reader.next)
        restarted.poll(now: timestamp.addingTimeInterval(6))
        restarted.poll(now: tomorrow)
        restarted.poll(now: tomorrow.addingTimeInterval(3))
        let pair = [
            NetworkTraffic(connection: .wifi(ssid: nil), bytesIn: 100, bytesOut: 0),
            NetworkTraffic(connection: wifi, bytesIn: 100, bytesOut: 0),
        ]
        XCTAssertEqual(try store.networkTraffic(dayEpoch: dayEpoch), pair)
        XCTAssertEqual(try store.networkTraffic(dayEpoch: tomorrowEpoch), pair)
    }

    func testV4MigrationKeepsHistoricalTrafficAndStartsWithNoBreakdown() throws {
        let path = directory.appendingPathComponent("v4.sqlite").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }
        try Migrations.applyV1(db)
        try Migrations.applyV2(db)
        try Migrations.applyV3(db)
        try Migrations.applyV4(db)
        try execSQL(db, "PRAGMA user_version = 4;")
        try execSQL(db, "INSERT INTO samples VALUES (\(dayEpoch!), 10, 'networkBytesIn', 900);")
        try execSQL(db, "INSERT INTO meta (key, ival) VALUES ('net.baseline.in:en0', 1500);")

        let migrated = try SampleStore(path: path)
        XCTAssertEqual(try migrated.totals(forDayEpoch: dayEpoch)[.networkBytesIn], 900)
        XCTAssertTrue(try migrated.networkTraffic(dayEpoch: dayEpoch).isEmpty)
        let collector = NetworkCollector(store: migrated) {
            [InterfaceCounters(name: "en0", bytesIn: 1_700, bytesOut: 0, connection: .ethernet)]
        }
        collector.poll(now: timestamp)
        XCTAssertEqual(try migrated.totals(forDayEpoch: dayEpoch)[.networkBytesIn], 1_100)
        XCTAssertEqual(try migrated.networkTraffic(dayEpoch: dayEpoch), [
            NetworkTraffic(connection: .ethernet, bytesIn: 200, bytesOut: 0),
        ])
    }
}
