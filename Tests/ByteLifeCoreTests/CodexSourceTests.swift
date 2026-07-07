import XCTest
@testable import ByteLifeCore

/// Covers CodexSource's cumulative-to-delta conversion, null-info skipping, dedup across a restart, the
/// recursive date-tree discovery, and its watcher lifecycle.
final class CodexSourceTests: XCTestCase {
    private var root: URL!
    private var dateDir: URL!
    private var sessionPath: String!
    private var dbPath: String!

    private static let sessionFileName = "rollout-2026-07-06T12-00-00-019cbf36-1053-78d1-af83-8801cbbad997.jsonl"

    override func setUpWithError() throws {
        let unique = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ByteLifeCodexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: Self.canonicalPath(unique.path), isDirectory: true)
        dateDir = root.appendingPathComponent("2026/07/06", isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        sessionPath = dateDir.appendingPathComponent(Self.sessionFileName).path
        dbPath = root.appendingPathComponent("test.sqlite").path
        try fixtureData("codex_sample").write(to: URL(fileURLWithPath: sessionPath))
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
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "missing fixture \(name).jsonl"
        )
        return try Data(contentsOf: url)
    }

    private var sampleDayEpoch: Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DayBucket.dayEpoch(for: formatter.date(from: "2026-07-06T12:00:00.000Z")!)
    }

    /// Backdates a file's modification time, faking a historical rollout so it falls outside the watcher's
    /// recency window.
    private func setModificationDate(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// Three days back, comfortably outside the two-day watch window.
    private var longAgo: Date { Date().addingTimeInterval(-3 * 24 * 60 * 60) }

    func testNormalSessionAccumulatesDeltasSkippingNullInfoAndDuplicates() throws {
        let store = try SampleStore(path: dbPath)
        let source = CodexSource(root: root, store: store)
        var recorded: [Sample] = []
        source.ingest(path: sessionPath) { recorded.append(contentsOf: $0) }

        // Cumulative snapshots 100/300/600 input yield deltas 100+200+300 = 600; the null-info heartbeat
        // is skipped and the repeated final snapshot contributes a zero delta.
        let totals = try store.totals(forDayEpoch: sampleDayEpoch)
        XCTAssertEqual(totals[.aiInputTokens], 600)
        XCTAssertEqual(totals[.aiOutputTokens], 90)
        // Cached-input cumulative 5/5/20 maps to the cache-read channel: 5 + 0 + 15 = 20.
        XCTAssertEqual(totals[.aiCacheReadTokens], 20)
        XCTAssertNil(totals[.aiCacheCreationTokens])
        XCTAssertEqual(recorded.filter { $0.kind == .aiInputTokens }.reduce(0) { $0 + $1.value }, 600)
    }

    func testCumulativeDecreaseClampsToZero() throws {
        let store = try SampleStore(path: dbPath)
        let path = dateDir.appendingPathComponent("rollout-decrease.jsonl").path
        try fixtureData("codex_decrease").write(to: URL(fileURLWithPath: path))
        let source = CodexSource(root: root, store: store)
        source.ingest(path: path) { _ in }

        // Deltas: 100, then a decrease to 50 clamps to 0, then 120 - 50 = 70. Total 170, never negative.
        let totals = try store.totals(forDayEpoch: sampleDayEpoch)
        XCTAssertEqual(totals[.aiInputTokens], 170)
        XCTAssertEqual(totals[.aiOutputTokens], 17)
        XCTAssertEqual(totals[.aiCacheReadTokens], 9)
    }

    func testDedupSurvivesRestartReingestingFromZero() throws {
        var totalsBefore: [MetricKind: Int64] = [:]
        do {
            let store = try SampleStore(path: dbPath)
            let source = CodexSource(root: root, store: store)
            source.ingest(path: sessionPath) { _ in }
            totalsBefore = try store.totals(forDayEpoch: sampleDayEpoch)
            XCTAssertEqual(totalsBefore[.aiInputTokens], 600)
        }

        // Restart: reopen the same store and clear the persisted offset/inode so the file is re-read
        // from byte 0, which resets the cumulative baselines and ordinals identically.
        let store = try SampleStore(path: dbPath)
        try store.setMetaInt(CodexSource.offsetKey(forPath: sessionPath), 0)
        try store.setMetaInt(CodexSource.inodeKey(forPath: sessionPath), 0)

        let source = CodexSource(root: root, store: store)
        var reRecorded: [Sample] = []
        source.ingest(path: sessionPath) { reRecorded.append(contentsOf: $0) }

        // Every dedup key was already in the ledger, so nothing new records and totals are unchanged.
        XCTAssertTrue(reRecorded.isEmpty)
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch), totalsBefore)
    }

    func testDiscoveryRecursesDateTreeAndIngests() throws {
        let store = try SampleStore(path: dbPath)
        let source = CodexSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))
        // The year/month/day directories are each watched, proving recursion into the date tree.
        XCTAssertTrue(source.watchedDirPaths.contains(dateDir.path))
        XCTAssertTrue(source.watchedDirPaths.contains(root.appendingPathComponent("2026").path))
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 600)
    }

    func testFileWatcherRemovedWhenFileDeleted() throws {
        let store = try SampleStore(path: dbPath)
        let source = CodexSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }
        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))

        try FileManager.default.removeItem(at: URL(fileURLWithPath: sessionPath))
        source.rediscover()
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testOldFileIsIngestedButNotWatched() throws {
        let store = try SampleStore(path: dbPath)
        try setModificationDate(sessionPath, longAgo)   // a historical rollout, outside the watch window
        let source = CodexSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        // Historical files are still backfilled once, but they earn no persistent watcher, so a machine
        // holding thousands of them never exhausts its file descriptors.
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 600)
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testOldFileThatGrowsIsReingestedOnNextDiscovery() throws {
        let store = try SampleStore(path: dbPath)
        try setModificationDate(sessionPath, longAgo)
        let source = CodexSource(root: root, store: store)
        var recorded: [Sample] = []
        source.start { recorded.append(contentsOf: $0) }
        defer { source.stop() }
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 600)

        // The historical file grows: a new cumulative snapshot appended raises input 600 -> 900 (delta 300).
        let appended = "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-06T12:00:08.000Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":900,\"cached_input_tokens\":20,\"output_tokens\":90,\"reasoning_output_tokens\":10,\"total_tokens\":1020}}}}\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: sessionPath))
        handle.seekToEndOfFile()
        handle.write(appended.data(using: .utf8)!)
        try handle.close()
        // Keep it backdated so the size-grew re-check path (not a watcher) drives the re-ingest.
        try setModificationDate(sessionPath, longAgo)

        recorded.removeAll()
        source.rediscover()

        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch)[.aiInputTokens], 900)
        XCTAssertEqual(recorded.filter { $0.kind == .aiInputTokens }.reduce(0) { $0 + $1.value }, 300)
        // Growth re-ingests an old file but still installs no watcher.
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testStartPrunesMetaForVanishedFiles() throws {
        let store = try SampleStore(path: dbPath)
        let deadPath = dateDir.appendingPathComponent("rollout-gone.jsonl").path
        try store.setMetaInt(CodexSource.offsetKey(forPath: deadPath), 30)
        try store.setMetaInt(CodexSource.cumInputKey(forPath: deadPath), 99)
        try store.setMetaInt(CodexSource.ordinalKey(forPath: deadPath), 4)

        let source = CodexSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertNil(try store.metaInt(CodexSource.offsetKey(forPath: deadPath)))
        XCTAssertNil(try store.metaInt(CodexSource.cumInputKey(forPath: deadPath)))
        XCTAssertNil(try store.metaInt(CodexSource.ordinalKey(forPath: deadPath)))
        // The live session's cursor was persisted on ingest.
        XCTAssertNotNil(try store.metaInt(CodexSource.offsetKey(forPath: sessionPath)))
    }
}
