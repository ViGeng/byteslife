import XCTest
@testable import ByteLifeCore

/// Covers the nettop route parser, the salted hashing, and the collector's record and degrade paths.
/// The sample output mirrors real `nettop -m route -x -L 1` shape (per-host rows plus the default-route
/// summary), so the parser is proven against the format it must survive.
final class HostsSeenCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private var timestamp: Date!
    private var dayEpoch: Int64!

    private let sampleOutput = """
        time,,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,conn_att,conn_est,rtt_avg,
        17:13:19.525286,default -> en14 -> 131.159.25.254,2976975322,428232800,41842,341383728,254969,6122,6016,25.84 ms,
        17:13:19.525224,2.18.66.167,14486,3719,0,0,0,1,1,15.00 ms,
        17:13:19.522881,208.103.161.2,3814648,14628867,0,0,9843,8,8,22.38 ms,
        17:13:19.523171,185.199.110.153,24948,18397,0,0,0,1,1,9.00 ms,
        17:13:19.523211,2.18.66.167,3007,5868,0,0,0,1,1,21.00 ms,
        """

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
        timestamp = fixedTimestamp()
        dayEpoch = DayBucket.dayEpoch(for: timestamp)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testParserExtractsDistinctHostsAndSkipsHeaderAndDefaultRoute() {
        let hosts = NettopRouteParser.hosts(from: sampleOutput)
        // The header row and the "default -> ... -> gateway" summary are skipped; the repeated host is
        // deduplicated while first-seen order is kept.
        XCTAssertEqual(hosts, ["2.18.66.167", "208.103.161.2", "185.199.110.153"])
    }

    func testHasherIsDeterministicAndSaltedAndHidesTheHost() {
        let a = HostHasher.hash(host: "2.18.66.167", salt: "salt-1")
        let b = HostHasher.hash(host: "2.18.66.167", salt: "salt-1")
        let c = HostHasher.hash(host: "2.18.66.167", salt: "salt-2")
        XCTAssertEqual(a, b)                 // deterministic under a fixed salt
        XCTAssertNotEqual(a, c)              // a different salt gives a different hash
        XCTAssertEqual(a.count, 16)          // 16 hex chars, matching the receipt grammar
        XCTAssertFalse(a.contains("2.18"))   // never leaks the hostname
    }

    func testTickRecordsDistinctHostsAndDedupsWithinDay() throws {
        let collector = HostsSeenCollector(
            store: store,
            now: { self.timestamp },
            runNettop: { self.sampleOutput }
        )
        collector.tick()
        XCTAssertEqual(try store.distinctHosts(dayEpoch: dayEpoch), 3)
        XCTAssertEqual(collector.availability, .running)

        // Re-polling the same hosts within the day adds no new distinct sightings.
        collector.tick()
        XCTAssertEqual(try store.distinctHosts(dayEpoch: dayEpoch), 3)
    }

    func testRepeatedRunFailureDegradesToSourceMissing() throws {
        let collector = HostsSeenCollector(
            store: store,
            failureThreshold: 3,
            now: { self.timestamp },
            runNettop: { nil }               // nettop cannot be run
        )
        collector.tick()
        collector.tick()
        XCTAssertEqual(collector.availability, .running)   // not yet past the threshold
        collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertEqual(try store.distinctHosts(dayEpoch: dayEpoch), 0)
    }

    func testRecoveryAfterFailureReturnsToRunning() throws {
        var output: String? = nil
        let collector = HostsSeenCollector(
            store: store,
            failureThreshold: 2,
            now: { self.timestamp },
            runNettop: { output }
        )
        collector.tick(); collector.tick()
        XCTAssertEqual(collector.availability, .sourceMissing)

        output = sampleOutput
        collector.tick()
        XCTAssertEqual(collector.availability, .running)
        XCTAssertEqual(try store.distinctHosts(dayEpoch: dayEpoch), 3)
    }
}
