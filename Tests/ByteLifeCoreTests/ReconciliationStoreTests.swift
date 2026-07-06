import XCTest
import SQLite3
@testable import ByteLifeCore

final class ReconciliationStoreTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeReconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("recon.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleReconciliation(dayEpoch: Int64, hash: String = "a1b2c3d4e5f60718") -> Reconciliation {
        Reconciliation(
            dayEpoch: dayEpoch,
            closedAt: 1_783_296_100,
            receiptText: "RECEIPT BODY\nline two\n",
            contentHash: hash,
            stamp: "BALANCED",
            comment: "Filed as usual."
        )
    }

    // MARK: - v1 -> v2 migration

    func testMigratesPopulatedV1StoreToV2Additively() throws {
        let sampleDay: Int64 = 1_700_000_000
        try buildPopulatedV1Store(at: dbPath, sampleDay: sampleDay)

        // A fresh store on the same file runs the additive migration.
        let store = try SampleStore(path: dbPath)

        // Schema advanced to v2 and the new table exists.
        XCTAssertEqual(readUserVersion(dbPath), 2)
        XCTAssertTrue(tableExists(dbPath, "reconciliations"))

        // Every v1 row survived intact.
        let totals = try store.totals(forDayEpoch: sampleDay)
        XCTAssertEqual(totals[.networkBytesIn], 800)          // 500 + 300 across two minutes
        XCTAssertEqual(try store.metaInt("net.baseline.in:en0"), 4_242)
        // The pre-existing dedup key is still present, so re-marking it returns false.
        XCTAssertFalse(try store.markSeen(dedupKey: "seen-key", dayEpoch: sampleDay))

        // The reconciliation API works on the migrated store: roundtrip then a refused double-post.
        let recon = sampleReconciliation(dayEpoch: sampleDay)
        XCTAssertTrue(try store.insertReconciliation(recon))
        XCTAssertEqual(try store.reconciliation(forDayEpoch: sampleDay), recon)
        XCTAssertEqual(try store.reconciledDayEpochs(), [sampleDay])
        XCTAssertFalse(try store.insertReconciliation(sampleReconciliation(dayEpoch: sampleDay, hash: "different")))
        // The refused post left the original stored, unchanged.
        XCTAssertEqual(try store.reconciliation(forDayEpoch: sampleDay)?.contentHash, "a1b2c3d4e5f60718")
    }

    // MARK: - Reconciliation APIs on a fresh v2 store

    func testInsertRoundtripAndDoublePostRefused() throws {
        let store = try SampleStore(path: dbPath)
        let recon = sampleReconciliation(dayEpoch: 1_783_296_000)

        XCTAssertNil(try store.reconciliation(forDayEpoch: 1_783_296_000))
        XCTAssertTrue(try store.insertReconciliation(recon))
        XCTAssertEqual(try store.reconciliation(forDayEpoch: 1_783_296_000), recon)

        // A day closes exactly once.
        XCTAssertFalse(try store.insertReconciliation(recon))
    }

    func testReconciledStampsMapEpochToStamp() throws {
        let store = try SampleStore(path: dbPath)
        XCTAssertTrue(try store.reconciledStamps().isEmpty)

        var balanced = sampleReconciliation(dayEpoch: 100)
        balanced = Reconciliation(dayEpoch: 100, closedAt: balanced.closedAt,
                                  receiptText: balanced.receiptText, contentHash: balanced.contentHash,
                                  stamp: "BALANCED", comment: balanced.comment)
        let flagged = Reconciliation(dayEpoch: 200, closedAt: 1, receiptText: "r",
                                     contentHash: "h", stamp: "FLAGGED", comment: "c")
        XCTAssertTrue(try store.insertReconciliation(balanced))
        XCTAssertTrue(try store.insertReconciliation(flagged))

        XCTAssertEqual(try store.reconciledStamps(), [100: "BALANCED", 200: "FLAGGED"])
    }

    func testReconciledDayEpochsNewestFirst() throws {
        let store = try SampleStore(path: dbPath)
        for day in [Int64(100), 300, 200] {
            XCTAssertTrue(try store.insertReconciliation(sampleReconciliation(dayEpoch: day)))
        }
        XCTAssertEqual(try store.reconciledDayEpochs(), [300, 200, 100])
    }

    // MARK: - Aggregate reads

    func testDayEpochsWithDataNewestFirst() throws {
        let store = try SampleStore(path: dbPath)
        try store.record([
            Sample(kind: .inputKeystrokes, value: 1, timestamp: day(1_700_000_000, minute: 1)),
            Sample(kind: .inputKeystrokes, value: 1, timestamp: day(1_700_086_400, minute: 1)),
            Sample(kind: .inputKeystrokes, value: 1, timestamp: day(1_700_259_200, minute: 1)),
        ])
        let days = try store.dayEpochsWithData()
        XCTAssertEqual(days, days.sorted(by: >))
        XCTAssertEqual(days.count, 3)
    }

    func testTotalsForSeveralDays() throws {
        let store = try SampleStore(path: dbPath)
        let d0 = day(1_700_000_000, minute: 1)
        let d1 = day(1_700_086_400, minute: 1)
        try store.record([
            Sample(kind: .networkBytesIn, value: 100, timestamp: d0),
            Sample(kind: .networkBytesIn, value: 50, timestamp: d0.addingTimeInterval(60)),
            Sample(kind: .diskBytesRead, value: 7, timestamp: d1),
        ])
        let e0 = DayBucket.dayEpoch(for: d0)
        let e1 = DayBucket.dayEpoch(for: d1)
        let batch = try store.totals(forDayEpochs: [e0, e1])
        XCTAssertEqual(batch[e0]?[.networkBytesIn], 150)
        XCTAssertEqual(batch[e1]?[.diskBytesRead], 7)
        XCTAssertNil(batch[e0]?[.diskBytesRead])
        XCTAssertTrue(try store.totals(forDayEpochs: []).isEmpty)
    }

    func testTrialBalanceSumsAllHistory() throws {
        let store = try SampleStore(path: dbPath)
        try store.record([
            Sample(kind: .networkBytesIn, value: 100, timestamp: day(1_700_000_000, minute: 1)),
            Sample(kind: .networkBytesIn, value: 200, timestamp: day(1_700_086_400, minute: 1)),
            Sample(kind: .diskBytesRead, value: 9, timestamp: day(1_700_172_800, minute: 1)),
        ])
        let trial = try store.trialBalance()
        XCTAssertEqual(trial[.networkBytesIn], 300)
        XCTAssertEqual(trial[.diskBytesRead], 9)
    }

    // MARK: - Helpers

    /// A timestamp built from a base epoch plus a minute offset, for deterministic bucketing.
    private func day(_ epoch: Int64, minute: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epoch + Int64(minute * 60)))
    }

    /// Builds a database holding only the v1 schema (no `reconciliations` table), user_version 1, and
    /// a few rows across all three v1 tables, using the raw SQLite C API so the migration is proven
    /// against a genuine pre-v2 file rather than a store the current code produced.
    private func buildPopulatedV1Store(at path: String, sampleDay: Int64) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        let db = handle!
        defer { sqlite3_close(db) }

        rawExec(db, """
            CREATE TABLE samples (
                day_epoch INTEGER NOT NULL,
                minute    INTEGER NOT NULL,
                kind      TEXT    NOT NULL,
                value     INTEGER NOT NULL,
                PRIMARY KEY (day_epoch, minute, kind)
            ) WITHOUT ROWID;
            """)
        rawExec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, ival INTEGER, sval TEXT);")
        rawExec(db, "CREATE TABLE ai_seen (dedup_key TEXT PRIMARY KEY, day_epoch INTEGER NOT NULL);")
        rawExec(db, "PRAGMA user_version = 1;")

        // The dedup row is dated recently so the store's open-time prune (45-day retention) keeps it,
        // letting the assertion prove the row survived migration rather than pruning.
        let recentSeenDay = Int64(Date().timeIntervalSince1970)
        rawExec(db, "INSERT INTO samples VALUES (\(sampleDay), 10, 'networkBytesIn', 500);")
        rawExec(db, "INSERT INTO samples VALUES (\(sampleDay), 11, 'networkBytesIn', 300);")
        rawExec(db, "INSERT INTO meta (key, ival) VALUES ('net.baseline.in:en0', 4242);")
        rawExec(db, "INSERT INTO ai_seen VALUES ('seen-key', \(recentSeenDay));")
    }

    private func rawExec(_ db: OpaquePointer, _ sql: String) {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            XCTFail("raw exec failed (\(rc)): \(message)\n\(sql)")
        }
    }

    private func readUserVersion(_ path: String) -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableExists(_ path: String, _ name: String) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }
}
