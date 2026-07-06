import XCTest
@testable import ByteLifeCore

final class DedupTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String!
    private var filePath: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeDedupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("test.sqlite").path
        filePath = dir.appendingPathComponent("session.jsonl").path
        try fixtureData("claude_sample").write(to: URL(fileURLWithPath: filePath))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "missing fixture \(name).jsonl"
        )
        return try Data(contentsOf: url)
    }

    /// The single local day every claude_sample line falls into (its timestamps are the same instant).
    private var sampleDayEpoch: Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DayBucket.dayEpoch(for: formatter.date(from: "2026-07-06T12:00:00.000Z")!)
    }

    private func inputTokens(_ samples: [Sample]) -> Int64 {
        samples.filter { $0.kind == .aiInputTokens }.reduce(0) { $0 + $1.value }
    }

    func testDedupCollapsesDuplicateUsagePair() throws {
        let store = try SampleStore(path: dbPath)
        let source = ClaudeCodeSource(root: dir, store: store)
        var recorded: [Sample] = []

        // The source records into the store itself; emit is just an observation hook now.
        source.ingest(path: filePath) { samples in recorded.append(contentsOf: samples) }

        // The byte-identical (S1,M3,R3) pair collapses to one: 100 + 200 + 300, not + another 300.
        XCTAssertEqual(inputTokens(recorded), 600)
        XCTAssertEqual(recorded.filter { $0.kind == .aiInputTokens }.count, 3)
        let totals = try store.totals(forDayEpoch: sampleDayEpoch)
        XCTAssertEqual(totals[.aiInputTokens], 600)
        // Cache channels sum across the three distinct events: 5 + 0 + 7 and 2 + 0 + 1.
        XCTAssertEqual(totals[.aiCacheCreationTokens], 12)
        XCTAssertEqual(totals[.aiCacheReadTokens], 3)
    }

    func testDedupSurvivesRestartReingestingFromZero() throws {
        var totalsBefore: [MetricKind: Int64] = [:]

        // First run: ingest, then let the store and source deallocate to mimic a process exit.
        do {
            let store = try SampleStore(path: dbPath)
            let source = ClaudeCodeSource(root: dir, store: store)
            source.ingest(path: filePath) { _ in }
            totalsBefore = try store.totals(forDayEpoch: sampleDayEpoch)
            XCTAssertEqual(totalsBefore[.aiInputTokens], 600)
        }

        // Restart: reopen the same store (its ai_seen ledger persists) and force a re-read from
        // offset 0 by clearing the persisted per-file offset and inode.
        let store = try SampleStore(path: dbPath)
        try store.setMetaInt(ClaudeCodeSource.offsetKey(forPath: filePath), 0)
        try store.setMetaInt(ClaudeCodeSource.inodeKey(forPath: filePath), 0)

        let source = ClaudeCodeSource(root: dir, store: store)
        var reRecorded: [Sample] = []
        source.ingest(path: filePath) { samples in reRecorded.append(contentsOf: samples) }

        // Every key was already in the ledger, so nothing new is emitted and totals are unchanged.
        XCTAssertTrue(reRecorded.isEmpty)
        XCTAssertEqual(try store.totals(forDayEpoch: sampleDayEpoch), totalsBefore)
    }

    func testRotationIngestsNewFileButStillDedupsOverlap() throws {
        let store = try SampleStore(path: dbPath)
        let source = ClaudeCodeSource(root: dir, store: store)
        var recorded: [Sample] = []
        let emit: ([Sample]) -> Void = { samples in recorded.append(contentsOf: samples) }

        source.ingest(path: filePath, emit: emit)
        XCTAssertEqual(inputTokens(recorded), 600)

        // Rotate: replace the file with a fresh inode carrying a new session plus a repeat of an
        // already-seen (S1,M1,R1) key.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: filePath))
        try fixtureData("claude_rotated").write(to: URL(fileURLWithPath: filePath))

        source.ingest(path: filePath, emit: emit)

        // 600 from the original file plus 1000 + 2000 from the two new S2 events; the repeated
        // (S1,M1,R1) line is deduped, so the total is 3600, not 3700.
        XCTAssertEqual(inputTokens(recorded), 3600)
    }

    // MARK: - Failed ingest advances nothing

    /// A store whose `ingest` always throws, to prove the source leaves its cursor unadvanced (and so
    /// retries) when a commit fails.
    private final class FailingStore: AIUsageStore, @unchecked Sendable {
        struct Boom: Error {}
        private let lock = NSLock()
        private var _ingestCalls = 0
        var ingestCalls: Int { lock.lock(); defer { lock.unlock() }; return _ingestCalls }

        func ingest(events: [AIIngestEvent], meta: [(String, Int64)]) throws -> [Sample] {
            lock.lock(); _ingestCalls += 1; lock.unlock()
            throw Boom()
        }
        func metaInt(_ key: String) throws -> Int64? { nil }
        func metaKeys(withPrefix prefix: String) throws -> [String] { [] }
        func deleteMeta(key: String) throws {}
    }

    func testFailedIngestLeavesCursorUnadvancedAndRetries() throws {
        let failing = FailingStore()
        let source = ClaudeCodeSource(root: dir, store: failing)
        var emitted: [Sample] = []

        source.ingest(path: filePath) { emitted.append(contentsOf: $0) }
        // The commit threw, so nothing is emitted and the in-memory cursor never advanced.
        XCTAssertTrue(emitted.isEmpty)
        // A second ingest re-reads the same bytes (the retry), calling the store again.
        source.ingest(path: filePath) { emitted.append(contentsOf: $0) }
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertEqual(failing.ingestCalls, 2)
    }

    // MARK: - AICollector wiring

    private final class FakeSource: AIUsageSource, @unchecked Sendable {
        let id: String
        private let lock = NSLock()
        private var _available: Bool
        private var _started = false
        private var _stopped = false

        init(id: String, available: Bool) {
            self.id = id
            self._available = available
        }

        var available: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _available }
            set { lock.lock(); _available = newValue; lock.unlock() }
        }
        var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

        var isAvailable: Bool { available }
        func start(emit: @escaping ([Sample]) -> Void) { lock.lock(); _started = true; lock.unlock() }
        func stop() { lock.lock(); _stopped = true; lock.unlock() }
    }

    func testAICollectorStartsAvailableSourceAndReportsRunning() throws {
        let store = try SampleStore(path: dbPath)
        let fake = FakeSource(id: "fake", available: true)
        let collector = AICollector(store: store, sources: [fake])
        collector.start()

        XCTAssertTrue(fake.started)
        XCTAssertEqual(collector.availability, .running)

        collector.stop()
        XCTAssertTrue(fake.stopped)
    }

    func testAICollectorReportsSourceMissingWhenNoSourceAvailable() throws {
        let store = try SampleStore(path: dbPath)
        let fake = FakeSource(id: "fake", available: false)
        let collector = AICollector(store: store, sources: [fake], recheckInterval: .milliseconds(20))
        XCTAssertEqual(collector.availability, .sourceMissing)
        collector.start()
        XCTAssertEqual(collector.availability, .sourceMissing)
        XCTAssertFalse(fake.started)
        collector.stop()
    }

    func testAICollectorRecoversWhenSourceBecomesAvailable() throws {
        let store = try SampleStore(path: dbPath)
        let fake = FakeSource(id: "fake", available: false)
        let collector = AICollector(store: store, sources: [fake], recheckInterval: .milliseconds(20))

        let ready = expectation(description: "source starts once it becomes available")
        collector.onAvailabilityChange = { if $0 == .running { ready.fulfill() } }
        collector.start()
        XCTAssertEqual(collector.availability, .sourceMissing)

        // The projects root appears after launch; the periodic recheck should pick it up.
        fake.available = true
        wait(for: [ready], timeout: 3)
        XCTAssertTrue(fake.started)
        XCTAssertEqual(collector.availability, .running)
        collector.stop()
    }
}
