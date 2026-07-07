import XCTest
@testable import ByteLifeCore

/// Covers GeminiSource's per-turn token ingest, its rewrite-in-place / reread-from-zero dedup, the
/// mtime skip that avoids re-parsing unchanged sessions, discovery into `<hash>/chats/`, and its
/// watcher lifecycle.
final class GeminiSourceTests: XCTestCase {
    private var root: URL!
    private var chatsDir: URL!
    private var sessionPath: String!
    private var dbPath: String!

    override func setUpWithError() throws {
        let unique = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ByteLifeGeminiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: Self.canonicalPath(unique.path), isDirectory: true)
        chatsDir = root.appendingPathComponent("hash01/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        sessionPath = chatsDir.appendingPathComponent("session-2026-07-06T12-00-e1a3.json").path
        dbPath = root.appendingPathComponent("test.sqlite").path
        try fixtureData("gemini_sample").write(to: URL(fileURLWithPath: sessionPath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    private func bumpModificationDate(_ path: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(seconds)],
            ofItemAtPath: path
        )
    }

    /// Sets a file's modification time to an absolute date, faking a historical session outside the
    /// watcher's recency window.
    private func setModificationDate(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Three days back, comfortably outside the two-day watch window.
    private var longAgo: Date { Date().addingTimeInterval(-3 * 24 * 60 * 60) }

    private var sampleDayEpoch: Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DayBucket.dayEpoch(for: formatter.date(from: "2026-07-06T12:00:05.000Z")!)
    }

    func testIngestRecordsPerTurnTokenMessages() throws {
        let store = try SampleStore(path: dbPath)
        let source = GeminiSource(root: root, store: store)
        source.ingest(path: sessionPath) { _ in }

        let totals = try store.totals(forDayEpoch: sampleDayEpoch)
        // m1 (100,10+3,5) + m2 (200,20+7,0). The user message carries no tokens and is skipped.
        XCTAssertEqual(totals[.aiInputTokens], 300)
        XCTAssertEqual(totals[.aiOutputTokens], 40)
        XCTAssertEqual(totals[.aiCacheReadTokens], 5)
    }

    func testRewriteInPlaceDedupsAndAddsOnlyNewMessages() throws {
        let store = try SampleStore(path: dbPath)
        let source = GeminiSource(root: root, store: store)
        source.ingest(path: sessionPath) { _ in }

        // Gemini rewrites the whole file: the same two messages plus a new third turn.
        try fixtureData("gemini_rewritten").write(to: URL(fileURLWithPath: sessionPath))
        try bumpModificationDate(sessionPath, by: 10)
        var added: [Sample] = []
        source.ingest(path: sessionPath) { added.append(contentsOf: $0) }

        // Only m3 (50, 5+2, 1) is new; m1 and m2 dedup away.
        XCTAssertEqual(added.filter { $0.kind == .aiInputTokens }.reduce(0) { $0 + $1.value }, 50)
        let totals = try store.totals(forDayEpoch: sampleDayEpoch)
        XCTAssertEqual(totals[.aiInputTokens], 350)
        XCTAssertEqual(totals[.aiOutputTokens], 47)
        XCTAssertEqual(totals[.aiCacheReadTokens], 6)
    }

    func testRestartRereadFromZeroDedups() throws {
        var totalsBefore: [MetricKind: Int64] = [:]
        do {
            let store = try SampleStore(path: dbPath)
            let source = GeminiSource(root: root, store: store)
            source.ingest(path: sessionPath) { _ in }
            totalsBefore = try store.totals(forDayEpoch: sampleDayEpoch)
        }

        // Restart: reopen the store and clear the persisted mtime so the whole file is re-read; the
        // message-id dedup keys collapse the re-read to nothing.
        let store = try SampleStore(path: dbPath)
        try store.deleteMeta(key: GeminiSource.mtimeKey(forPath: sessionPath))
        let source = GeminiSource(root: root, store: store)
        var reRecorded: [Sample] = []
        source.ingest(path: sessionPath) { reRecorded.append(contentsOf: $0) }

        XCTAssertTrue(reRecorded.isEmpty)
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch), totalsBefore)
    }

    func testUnchangedFileIsSkippedByMtime() throws {
        let store = try SampleStore(path: dbPath)
        let source = GeminiSource(root: root, store: store)
        source.ingest(path: sessionPath) { _ in }

        // A second ingest with no file change is skipped outright: nothing is emitted.
        var second: [Sample] = []
        source.ingest(path: sessionPath) { second.append(contentsOf: $0) }
        XCTAssertTrue(second.isEmpty)
    }

    func testHighWaterMarkPreventsDoubleCountAfterAiSeenPrune() throws {
        let store = try SampleStore(path: dbPath)
        let source = GeminiSource(root: root, store: store)
        source.ingest(path: sessionPath) { _ in }
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 300)

        // Simulate the ai_seen ledger having pruned m1/m2's keys (aged past the 45-day window). A negative
        // window drops even today's rows, so the dedup safety net is gone; only the per-file high-water
        // mark can now keep an appended file from re-counting its early messages.
        store.pruneAISeen(olderThanDays: -1)

        // Gemini rewrites the whole file with a third turn appended, and its mtime advances.
        try fixtureData("gemini_rewritten").write(to: URL(fileURLWithPath: sessionPath))
        try bumpModificationDate(sessionPath, by: 10)
        var added: [Sample] = []
        source.ingest(path: sessionPath) { added.append(contentsOf: $0) }

        // Only m3 (50 input) is added; m1 and m2 are skipped by the high-water mark, not by ai_seen.
        XCTAssertEqual(added.filter { $0.kind == .aiInputTokens }.reduce(0) { $0 + $1.value }, 50)
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 350)
    }

    func testOldFileIsIngestedButNotWatched() throws {
        let store = try SampleStore(path: dbPath)
        try setModificationDate(sessionPath, longAgo)   // a historical session, outside the watch window
        let source = GeminiSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        // Backfilled once but not watched, so a machine with many historical sessions keeps its fds.
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 300)
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testOldFileThatChangesIsReingestedOnNextDiscovery() throws {
        let store = try SampleStore(path: dbPath)
        try setModificationDate(sessionPath, longAgo)
        let source = GeminiSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 300)

        // The historical session is rewritten with a third turn; its mtime advances but stays backdated,
        // so the cheap mtime re-check (not a watcher) drives the re-ingest.
        try fixtureData("gemini_rewritten").write(to: URL(fileURLWithPath: sessionPath))
        try setModificationDate(sessionPath, longAgo.addingTimeInterval(120))
        source.rediscover()

        // Only m3 (50 input) is added; the file is re-ingested but still not watched.
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 350)
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testDiscoveryFindsChatsSessionsAndWatches() throws {
        let store = try SampleStore(path: dbPath)
        let source = GeminiSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))
        XCTAssertTrue(source.watchedDirPaths.contains(chatsDir.path))
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 300)
    }

    func testFileWatcherRemovedWhenFileDeleted() throws {
        let store = try SampleStore(path: dbPath)
        let source = GeminiSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }
        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))

        try FileManager.default.removeItem(at: URL(fileURLWithPath: sessionPath))
        source.rediscover()
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testStartPrunesMetaForVanishedFiles() throws {
        let store = try SampleStore(path: dbPath)
        let deadPath = chatsDir.appendingPathComponent("session-gone.json").path
        try store.setMetaInt(GeminiSource.mtimeKey(forPath: deadPath), 12345)

        let source = GeminiSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertNil(try store.metaInt(GeminiSource.mtimeKey(forPath: deadPath)))
        XCTAssertNotNil(try store.metaInt(GeminiSource.mtimeKey(forPath: sessionPath)))
    }
}
