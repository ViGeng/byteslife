import XCTest
@testable import ByteLifeCore

final class ShellHistoryCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        store = nil
        directory = nil
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to name: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path(name)))
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    private var commandsToday: Int64 {
        (try? store.totals(forDayEpoch: DayBucket.dayEpoch(for: Date()))[.commandsRun]) ?? 0
    }

    // MARK: - Pure counter

    func testCounterCountsExtendedZshHeadersAcrossMultiLineEntries() {
        var counter = ShellHistoryCounter()
        // Three entries; the middle one spans two backslash-continuation lines.
        let lines = [
            ": 1700000000:0;git status",
            ": 1700000001:5;echo one \\",
            "two \\",
            "three",
            ": 1700000002:0;ls",
        ]
        XCTAssertEqual(counter.count(lines: lines), 3)
        XCTAssertTrue(counter.extended)
    }

    func testCounterCountsPlainBashNonEmptyLines() {
        var counter = ShellHistoryCounter()
        let lines = ["git status", "ls -la", "", "echo hi"]
        XCTAssertEqual(counter.count(lines: lines), 3)
        XCTAssertFalse(counter.extended)
    }

    func testCounterCarriesContinuationAcrossChunks() {
        var counter = ShellHistoryCounter()
        // A header whose command continues, split across three separate reads.
        XCTAssertEqual(counter.count(lines: [": 1:0;echo \\"]), 1)
        XCTAssertTrue(counter.continuing)
        XCTAssertEqual(counter.count(lines: ["more text"]), 0)
        XCTAssertFalse(counter.continuing)
        XCTAssertEqual(counter.count(lines: [": 2:0;ls"]), 1)
    }

    // MARK: - Collector

    func testFirstSightBaselinesThenCountsAppends() throws {
        try write(": 1700000000:0;old one\n: 1700000001:0;old two\n", to: ".zsh_history")
        let collector = ShellHistoryCollector(store: store, roots: [path(".zsh_history")])

        // First sight of a pre-existing history baselines to its end and counts nothing.
        collector.ingest(path: path(".zsh_history"))
        XCTAssertEqual(commandsToday, 0)

        // Two freshly appended extended entries are counted.
        try append(": 1700000100:0;git commit\n: 1700000101:2;make test\n", to: ".zsh_history")
        collector.ingest(path: path(".zsh_history"))
        XCTAssertEqual(commandsToday, 2)
    }

    func testPlainBashHistoryCountsAppendedLines() throws {
        try write("", to: ".bash_history")
        let collector = ShellHistoryCollector(store: store, roots: [path(".bash_history")])
        collector.ingest(path: path(".bash_history"))
        XCTAssertEqual(commandsToday, 0)

        try append("cd /tmp\nls\necho done\n", to: ".bash_history")
        collector.ingest(path: path(".bash_history"))
        XCTAssertEqual(commandsToday, 3)
    }

    func testTruncationResetsAndRecounts() throws {
        try write("", to: ".zsh_history")
        let collector = ShellHistoryCollector(store: store, roots: [path(".zsh_history")])
        collector.ingest(path: path(".zsh_history"))

        try append(": 1:0;one\n: 2:0;two\n: 3:0;three\n", to: ".zsh_history")
        collector.ingest(path: path(".zsh_history"))
        XCTAssertEqual(commandsToday, 3)

        // A shell that rewrote the file smaller (HISTSIZE trim) shrinks it below the consumed offset. The
        // tailer restarts from byte 0, so the two surviving entries are recounted (the burst caveat).
        try write(": 4:0;four\n: 5:0;five\n", to: ".zsh_history")
        collector.ingest(path: path(".zsh_history"))
        XCTAssertEqual(commandsToday, 5)
    }

    func testMissingHistoriesDegradeToSourceMissing() {
        let collector = ShellHistoryCollector(
            store: store,
            roots: [path(".zsh_history"), path(".bash_history")]
        )
        collector.rediscover()
        XCTAssertEqual(collector.availability, .sourceMissing)
    }

    func testAppearingHistoryReturnsToRunning() throws {
        let collector = ShellHistoryCollector(store: store, roots: [path(".zsh_history")])
        collector.rediscover()
        XCTAssertEqual(collector.availability, .sourceMissing)

        try write(": 1:0;hello\n", to: ".zsh_history")
        collector.rediscover()
        XCTAssertEqual(collector.availability, .running)
    }
}
