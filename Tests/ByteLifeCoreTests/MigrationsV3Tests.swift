import XCTest
import SQLite3
@testable import ByteLifeCore

/// Proves the v3 step is a safe additive migration against a GENUINE populated v2 store: a database
/// built with the real v1 and v2 DDL, filled with rows, and stuck at `user_version = 2`, then reopened
/// through the full migrator. The pre-existing data must survive byte for byte and the two new tables
/// must appear, matching the data-safety rule that schema changes are additive migrations proven against
/// a populated prior-version store.
final class MigrationsV3Tests: XCTestCase {
    private var dir: URL!
    private var path: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeMigrateV3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("prior.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Builds a populated store carrying exactly the v1 and v2 schema, pinned at `user_version = 2`.
    private func makePopulatedV2Store(dayEpoch: Int64) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(path, &handle, flags, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }

        try Migrations.applyV1(db)
        try Migrations.applyV2(db)
        try execSQL(db, "PRAGMA user_version = 2;")

        try execSQL(db, "INSERT INTO samples (day_epoch, minute, kind, value) VALUES (\(dayEpoch), 10, 'networkBytesIn', 1234);")
        try execSQL(db, "INSERT INTO samples (day_epoch, minute, kind, value) VALUES (\(dayEpoch), 11, 'inputKeystrokes', 77);")
        try execSQL(db, "INSERT INTO meta (key, ival) VALUES ('net.baseline.in:en0', 999);")
        try execSQL(db, "INSERT INTO ai_seen (dedup_key, day_epoch) VALUES ('k1', \(dayEpoch));")
        try execSQL(db, """
            INSERT INTO reconciliations (day_epoch, closed_at, receipt_text, content_hash, stamp, comment)
            VALUES (\(dayEpoch), 111, 'BODY', 'abcdef0123456789', 'BALANCED', 'note');
            """)
    }

    func testMigrateFromPopulatedV2AddsV3TablesAndPreservesData() throws {
        let dayEpoch = DayBucket.dayEpoch(for: Date())
        try makePopulatedV2Store(dayEpoch: dayEpoch)

        do {
            // Reopening runs the v3 step only; v1 and v2 are skipped because user_version is already 2.
            let store = try SampleStore(path: path)

            // Every v2 row survived unchanged.
            let totals = try store.totals(forDayEpoch: dayEpoch)
            XCTAssertEqual(totals[.networkBytesIn], 1234)
            XCTAssertEqual(totals[.inputKeystrokes], 77)
            XCTAssertEqual(try store.metaInt("net.baseline.in:en0"), 999)
            let recon = try XCTUnwrap(try store.reconciliation(forDayEpoch: dayEpoch))
            XCTAssertEqual(recon.contentHash, "abcdef0123456789")
            XCTAssertEqual(recon.stamp, "BALANCED")
            // The dedup ledger survived: re-marking the pre-existing key is a no-op.
            XCTAssertFalse(try store.markSeen(dedupKey: "k1", dayEpoch: dayEpoch))

            // The two new v3 tables exist and behave.
            try store.recordFocus(dayEpoch: dayEpoch, bundleId: "com.apple.Safari", seconds: 30)
            try store.recordFocus(dayEpoch: dayEpoch, bundleId: "com.apple.Safari", seconds: 15)
            XCTAssertEqual(try store.topFocus(dayEpoch: dayEpoch, limit: 5).first?.seconds, 45)
            XCTAssertTrue(try store.markHostSeen(dayEpoch: dayEpoch, hash: "deadbeefdeadbeef"))
            XCTAssertFalse(try store.markHostSeen(dayEpoch: dayEpoch, hash: "deadbeefdeadbeef"))
            XCTAssertEqual(try store.distinctHosts(dayEpoch: dayEpoch), 1)
        }

        // The store closed with the block; a fresh raw handle confirms the version advanced through the
        // v3 step to the build's current target (later additive steps run too and leave v3's tables intact).
        XCTAssertEqual(try readUserVersion(), Migrations.currentVersion)
    }

    private func readUserVersion() throws -> Int32 {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }
}
