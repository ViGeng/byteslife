import XCTest
@testable import ByteLifeCore

/// Covers ClaudeCodeSource's watcher lifecycle (removal on delete, in-place replacement re-tail) and
/// stale per-file meta cleanup. The token-dedup flow itself lives in DedupTests.
final class ClaudeCodeSourceTests: XCTestCase {
    private var root: URL!
    private var projectDir: URL!
    private var sessionPath: String!
    private var dbPath: String!

    override func setUpWithError() throws {
        let unique = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ByteLifeCCSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        // Canonicalize with realpath: NSTemporaryDirectory() is a /var symlink but directory
        // enumeration reports the resolved /private/var path, so watcher keys (built from enumeration)
        // must be compared against the same canonical base.
        root = URL(fileURLWithPath: Self.canonicalPath(unique.path), isDirectory: true)
        projectDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        sessionPath = projectDir.appendingPathComponent("session.jsonl").path
        dbPath = root.appendingPathComponent("test.sqlite").path
        try fixtureData("claude_sample").write(to: URL(fileURLWithPath: sessionPath))
    }

    private static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "missing fixture \(name).jsonl"
        )
        return try Data(contentsOf: url)
    }

    private func inputTokens(_ samples: [Sample]) -> Int64 {
        samples.filter { $0.kind == .aiInputTokens }.reduce(0) { $0 + $1.value }
    }

    /// Backdates a file's modification time, faking a historical transcript outside the watch window.
    private func setModificationDate(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private var longAgo: Date { Date().addingTimeInterval(-3 * 24 * 60 * 60) }

    /// The store totals for a day are only exposed via the store, so read input tokens straight from it.
    private func storedInputTokens(_ store: SampleStore) throws -> Int64 {
        let epoch = DayBucket.dayEpoch(for: ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z")!)
        return try store.totals(forDayEpoch: epoch)[.aiInputTokens] ?? 0
    }

    func testFileWatcherRemovedWhenFileDeleted() throws {
        let store = try SampleStore(path: dbPath)
        let source = ClaudeCodeSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))

        // Delete the session file, then let discovery reconcile.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: sessionPath))
        source.rediscover()

        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testProjectWatcherRemovedWhenProjectDeleted() throws {
        let store = try SampleStore(path: dbPath)
        let source = ClaudeCodeSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertTrue(source.watchedProjectPaths.contains(projectDir.path))

        try FileManager.default.removeItem(at: projectDir)
        source.rediscover()

        XCTAssertFalse(source.watchedProjectPaths.contains(projectDir.path))
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testInPlaceReplacementReTails() throws {
        let store = try SampleStore(path: dbPath)
        let source = ClaudeCodeSource(root: root, store: store)
        var recorded: [Sample] = []
        source.start { recorded.append(contentsOf: $0) }
        defer { source.stop() }

        // Initial discovery ingested the S1 session: 100 + 200 + 300 input, the duplicate pair deduped.
        XCTAssertEqual(inputTokens(recorded), 600)

        // Replace the file in place with a fresh inode carrying a new session (S2) plus a repeat of an
        // already-seen (S1,M1,R1) line, then simulate the watcher's delete/rename event.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: sessionPath))
        try fixtureData("claude_rotated").write(to: URL(fileURLWithPath: sessionPath))
        source.simulateVanish(path: sessionPath)

        // The replacement is re-tailed from zero: 1000 + 2000 of new S2 tokens; the repeated S1 line
        // is deduped, so the running total is 3600, not 3700. And the watcher is reinstalled.
        XCTAssertEqual(inputTokens(recorded), 3600)
        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))
    }

    func testOldFileIsIngestedButNotWatched() throws {
        let store = try SampleStore(path: dbPath)
        try setModificationDate(sessionPath, longAgo)   // a historical transcript, outside the watch window
        let source = ClaudeCodeSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        // Backfilled once (100 + 200 + 300, the duplicate pair deduped) but not watched.
        XCTAssertEqual(try storedInputTokens(store), 600)
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testRecentFileIsIngestedAndWatched() throws {
        // The default fixture was just written, so its mtime is within the recency window: it earns both.
        let store = try SampleStore(path: dbPath)
        let source = ClaudeCodeSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        XCTAssertEqual(try storedInputTokens(store), 600)
        XCTAssertTrue(source.watchedFilePaths.contains(sessionPath))
    }

    func testOldFileThatGrowsIsReingestedOnNextDiscovery() throws {
        let store = try SampleStore(path: dbPath)
        try setModificationDate(sessionPath, longAgo)
        let source = ClaudeCodeSource(root: root, store: store)
        var recorded: [Sample] = []
        source.start { recorded.append(contentsOf: $0) }
        defer { source.stop() }
        XCTAssertEqual(try storedInputTokens(store), 600)

        // The historical file grows: a new assistant turn appended adds 500 input tokens.
        let appended = "{\"type\":\"assistant\",\"sessionId\":\"S1\",\"requestId\":\"R9\",\"uuid\":\"U9\",\"timestamp\":\"2026-07-06T12:00:00.000Z\",\"message\":{\"id\":\"M9\",\"role\":\"assistant\",\"usage\":{\"input_tokens\":500,\"output_tokens\":50}}}\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: sessionPath))
        handle.seekToEndOfFile()
        handle.write(appended.data(using: .utf8)!)
        try handle.close()
        // Keep it backdated so the size-grew re-check path (not a watcher) drives the re-ingest.
        try setModificationDate(sessionPath, longAgo)

        recorded.removeAll()
        source.rediscover()

        XCTAssertEqual(try storedInputTokens(store), 1_100)
        XCTAssertEqual(inputTokens(recorded), 500)
        XCTAssertFalse(source.watchedFilePaths.contains(sessionPath))
    }

    func testStartPrunesMetaForVanishedFiles() throws {
        let store = try SampleStore(path: dbPath)
        let deadPath = projectDir.appendingPathComponent("gone.jsonl").path
        try store.setMetaInt(ClaudeCodeSource.offsetKey(forPath: sessionPath), 10)
        try store.setMetaInt(ClaudeCodeSource.inodeKey(forPath: sessionPath), 20)
        try store.setMetaInt(ClaudeCodeSource.offsetKey(forPath: deadPath), 30)
        try store.setMetaInt(ClaudeCodeSource.inodeKey(forPath: deadPath), 40)

        let source = ClaudeCodeSource(root: root, store: store)
        source.start { _ in }
        defer { source.stop() }

        // The vanished file's offset/inode rows are gone; the live file's remain (re-tailed on start).
        XCTAssertNil(try store.metaInt(ClaudeCodeSource.offsetKey(forPath: deadPath)))
        XCTAssertNil(try store.metaInt(ClaudeCodeSource.inodeKey(forPath: deadPath)))
        XCTAssertNotNil(try store.metaInt(ClaudeCodeSource.offsetKey(forPath: sessionPath)))
    }
}
