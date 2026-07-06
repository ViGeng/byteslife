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
