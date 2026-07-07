import XCTest
@testable import ByteLifeCore

/// Drives the sampling estimator with an injected frontmost reader and clock, so per-app crediting and
/// the per-minute flush are deterministic. The scheduler is not exercised; `poll()` and `flush()` are
/// called directly.
final class AppFocusCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private var timestamp: Date!
    private var dayEpoch: Int64!

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
        timestamp = fixedTimestamp()
        dayEpoch = DayBucket.dayEpoch(for: timestamp)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testEachPollCreditsTheFrontmostAppAndFlushesOnTheMinute() throws {
        var frontmost: String? = "com.a"
        let collector = AppFocusCollector(
            store: store,
            secondsPerPoll: 5,
            pollsPerFlush: 12,
            now: { self.timestamp },
            frontmostBundleID: { frontmost }
        )

        // Eleven polls accumulate but do not yet flush.
        for _ in 0..<11 { collector.poll() }
        XCTAssertTrue(try store.topFocus(dayEpoch: dayEpoch, limit: 5).isEmpty)

        // The twelfth poll trips the minute flush: 12 * 5 s = 60 s credited to com.a.
        collector.poll()
        XCTAssertEqual(try store.topFocus(dayEpoch: dayEpoch, limit: 5).first?.bundleId, "com.a")
        XCTAssertEqual(try store.topFocus(dayEpoch: dayEpoch, limit: 5).first?.seconds, 60)

        // The next minute goes to a different app; a nil frontmost (no bundle id) is skipped.
        frontmost = "com.b"
        for _ in 0..<6 { collector.poll() }
        frontmost = nil
        for _ in 0..<6 { collector.poll() }   // these six credit nobody, but still tick the flush counter

        let ranked = try store.topFocus(dayEpoch: dayEpoch, limit: 5)
        XCTAssertEqual(ranked.first?.bundleId, "com.a")   // 60 s still leads
        XCTAssertEqual(ranked.first(where: { $0.bundleId == "com.b" })?.seconds, 30)
    }

    func testManualFlushWritesTheAccumulatedTail() throws {
        let collector = AppFocusCollector(
            store: store,
            secondsPerPoll: 5,
            pollsPerFlush: 12,
            now: { self.timestamp },
            frontmostBundleID: { "com.tail" }
        )
        for _ in 0..<4 { collector.poll() }   // 20 s, below the flush threshold
        XCTAssertTrue(try store.topFocus(dayEpoch: dayEpoch, limit: 5).isEmpty)
        collector.flush()
        XCTAssertEqual(try store.topFocus(dayEpoch: dayEpoch, limit: 5).first?.seconds, 20)
    }
}
