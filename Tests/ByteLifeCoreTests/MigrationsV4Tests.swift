import XCTest
import SQLite3
@testable import ByteLifeCore

/// Proves the v4 step is a safe additive migration against a GENUINE populated v3 store: a database
/// built with the real v1, v2, and v3 DDL, filled with rows across every existing table, and stuck at
/// `user_version = 3`, then reopened through the full migrator. The pre-existing data must survive byte
/// for byte and the three new tables (ai_models, ai_sessions, gauges) must appear, matching the
/// data-safety rule that schema changes are additive migrations proven against a populated prior store.
final class MigrationsV4Tests: XCTestCase {
    private var dir: URL!
    private var path: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeMigrateV4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("prior.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Builds a populated store carrying exactly the v1, v2, and v3 schema, pinned at `user_version = 3`.
    private func makePopulatedV3Store(dayEpoch: Int64) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(path, &handle, flags, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close_v2(db) }

        try Migrations.applyV1(db)
        try Migrations.applyV2(db)
        try Migrations.applyV3(db)
        try execSQL(db, "PRAGMA user_version = 3;")

        try execSQL(db, "INSERT INTO samples (day_epoch, minute, kind, value) VALUES (\(dayEpoch), 10, 'aiInputTokens', 4321);")
        try execSQL(db, "INSERT INTO meta (key, ival) VALUES ('ai.codex.offset:/x.jsonl', 88);")
        try execSQL(db, "INSERT INTO ai_seen (dedup_key, day_epoch) VALUES ('seen-key', \(dayEpoch));")
        try execSQL(db, """
            INSERT INTO reconciliations (day_epoch, closed_at, receipt_text, content_hash, stamp, comment)
            VALUES (\(dayEpoch), 222, 'BODY', 'fedcba9876543210', 'BALANCED', 'note');
            """)
        try execSQL(db, "INSERT INTO focus (day_epoch, bundle_id, seconds) VALUES (\(dayEpoch), 'com.apple.Terminal', 120);")
        try execSQL(db, "INSERT INTO hosts_seen (day_epoch, host_hash) VALUES (\(dayEpoch), 'cafebabecafebabe');")
    }

    func testMigrateFromPopulatedV3AddsV4TablesAndPreservesData() throws {
        let anchor = ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z")!
        let dayEpoch = DayBucket.dayEpoch(for: anchor)
        try makePopulatedV3Store(dayEpoch: dayEpoch)

        do {
            // Reopening runs the v4 step only; v1-v3 are skipped because user_version is already 3.
            let store = try SampleStore(path: path)

            // Every v3 row survived unchanged across all pre-existing tables.
            XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.aiInputTokens], 4321)
            XCTAssertEqual(try store.metaInt("ai.codex.offset:/x.jsonl"), 88)
            XCTAssertFalse(try store.markSeen(dedupKey: "seen-key", dayEpoch: dayEpoch))
            let recon = try XCTUnwrap(try store.reconciliation(forDayEpoch: dayEpoch))
            XCTAssertEqual(recon.contentHash, "fedcba9876543210")
            XCTAssertEqual(try store.topFocus(dayEpoch: dayEpoch, limit: 5).first?.seconds, 120)
            XCTAssertEqual(try store.distinctHosts(dayEpoch: dayEpoch), 1)

            // The new ai_models / ai_sessions ledgers work: ingest one attributed event and read it back.
            let attribution = AIUsageAttribution(
                source: "codex", model: "gpt-5.4", sessionId: "sess-A", timestamp: anchor
            )
            _ = try store.ingest(
                events: [AIIngestEvent(
                    dedupKey: "v4-key",
                    samples: [Sample(kind: .aiOutputTokens, value: 90, timestamp: anchor)],
                    attribution: attribution
                )],
                meta: []
            )
            let models = try store.aiModelTotals(dayEpoch: dayEpoch)
            XCTAssertEqual(models.count, 1)
            XCTAssertEqual(models.first?.model, "gpt-5.4")
            XCTAssertEqual(models.first?.output, 90)
            XCTAssertEqual(try store.aiSessionStats(dayEpoch: dayEpoch).count, 1)

            // The new gauges table stores and reads a per-minute reading.
            try store.recordGauge(dayEpoch: dayEpoch, minute: 30, gauge: "cpuTemperature", value: 512)
            XCTAssertEqual(try store.gaugeSeries(gauge: "cpuTemperature", dayEpoch: dayEpoch)[30], 512)
        }

        // The store closed with the block; a fresh raw handle confirms the version advanced to 4.
        XCTAssertEqual(try readUserVersion(), 4)
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
