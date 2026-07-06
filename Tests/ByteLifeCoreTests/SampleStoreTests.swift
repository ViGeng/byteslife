import XCTest
@testable import ByteLifeCore

final class SampleStoreTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("test.sqlite").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A deterministic timestamp anchored to local midnight so it buckets predictably.
    private func date(dayOffset: Int, minute: Int, second: Int = 0) -> Date {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        let day = cal.date(byAdding: .day, value: dayOffset, to: midnight)!
        return day.addingTimeInterval(TimeInterval(minute * 60 + second))
    }

    func testUpsertAccumulatesAcrossRecordCalls() throws {
        let store = try SampleStore(path: dbPath)
        let t = date(dayOffset: 0, minute: 10)
        try store.record([Sample(kind: .inputKeystrokes, value: 3, timestamp: t)])
        // Same minute, different second: must land in the same cell and add, not overwrite.
        try store.record([Sample(kind: .inputKeystrokes, value: 5, timestamp: t.addingTimeInterval(20))])

        let totals = try store.totals(forDayEpoch: DayBucket.dayEpoch(for: t))
        XCTAssertEqual(totals[.inputKeystrokes], 8)
    }

    func testRecordSettingMetaLandsSamplesAndBaselinesTogether() throws {
        let store = try SampleStore(path: dbPath)
        let t = date(dayOffset: 0, minute: 30)
        try store.record(
            [Sample(kind: .networkBytesIn, value: 500, timestamp: t)],
            settingMeta: ["net.baseline.in:en0": 1_500, "net.baseline.out:en0": 2_600]
        )

        XCTAssertEqual(try store.totals(forDayEpoch: DayBucket.dayEpoch(for: t))[.networkBytesIn], 500)
        XCTAssertEqual(try store.metaInt("net.baseline.in:en0"), 1_500)
        XCTAssertEqual(try store.metaInt("net.baseline.out:en0"), 2_600)

        // Meta-only writes (a first poll with no positive delta) still persist the baselines.
        try store.record([], settingMeta: ["net.baseline.in:en0": 1_800])
        XCTAssertEqual(try store.metaInt("net.baseline.in:en0"), 1_800)
    }

    func testTotalsRollUpAcrossMinutesAndKinds() throws {
        let store = try SampleStore(path: dbPath)
        let base = date(dayOffset: 0, minute: 100)
        try store.record([
            Sample(kind: .networkBytesIn, value: 100, timestamp: base),
            Sample(kind: .networkBytesIn, value: 200, timestamp: base.addingTimeInterval(60)),
            Sample(kind: .networkBytesIn, value: 300, timestamp: base.addingTimeInterval(120)),
            Sample(kind: .networkBytesOut, value: 50, timestamp: base),
        ])

        let totals = try store.totals(forDayEpoch: DayBucket.dayEpoch(for: base))
        XCTAssertEqual(totals[.networkBytesIn], 600)
        XCTAssertEqual(totals[.networkBytesOut], 50)

        // A different day sees none of it.
        let otherDay = DayBucket.dayEpoch(for: date(dayOffset: 1, minute: 0))
        XCTAssertTrue(try store.totals(forDayEpoch: otherDay).isEmpty)
    }

    func testMetaRoundTripAndReopenPersistence() throws {
        do {
            let store = try SampleStore(path: dbPath)
            XCTAssertNil(try store.metaInt("net.baseline.en0"))
            XCTAssertNil(try store.metaString("ai.inode.session"))

            try store.setMetaInt("net.baseline.en0", 123_456)
            try store.setMetaString("ai.inode.session", "9988")
            XCTAssertEqual(try store.metaInt("net.baseline.en0"), 123_456)
            XCTAssertEqual(try store.metaString("ai.inode.session"), "9988")

            // Overwrite updates in place.
            try store.setMetaInt("net.baseline.en0", 999)
            XCTAssertEqual(try store.metaInt("net.baseline.en0"), 999)
        }

        // A fresh store on the same file sees the persisted values.
        let reopened = try SampleStore(path: dbPath)
        XCTAssertEqual(try reopened.metaInt("net.baseline.en0"), 999)
        XCTAssertEqual(try reopened.metaString("ai.inode.session"), "9988")
    }

    func testMarkSeenFirstTrueThenFalse() throws {
        let store = try SampleStore(path: dbPath)
        let epoch = DayBucket.dayEpoch(for: Date())
        XCTAssertTrue(try store.markSeen(dedupKey: "s1|m1|r1", dayEpoch: epoch))
        XCTAssertFalse(try store.markSeen(dedupKey: "s1|m1|r1", dayEpoch: epoch))
        // A different key is independent.
        XCTAssertTrue(try store.markSeen(dedupKey: "s1|m2|r2", dayEpoch: epoch))
    }

    func testIngestLandsKeysSamplesAndMetaAtomically() throws {
        let store = try SampleStore(path: dbPath)
        let t = date(dayOffset: 0, minute: 5)
        let events = [
            AIIngestEvent(dedupKey: "k1", samples: [Sample(kind: .aiInputTokens, value: 100, timestamp: t)]),
            AIIngestEvent(dedupKey: "k2", samples: [Sample(kind: .aiInputTokens, value: 200, timestamp: t)]),
        ]
        let recorded = try store.ingest(events: events, meta: [("off", 500), ("ino", 42)])

        // All three effects landed together: newly seen samples, their totals, and the meta offsets.
        XCTAssertEqual(recorded.reduce(0) { $0 + $1.value }, 300)
        XCTAssertEqual(try store.totals(forDayEpoch: DayBucket.dayEpoch(for: t))[.aiInputTokens], 300)
        XCTAssertEqual(try store.metaInt("off"), 500)
        XCTAssertEqual(try store.metaInt("ino"), 42)

        // Re-ingesting the same keys records nothing new (dedup) but still advances the offset meta.
        let again = try store.ingest(events: events, meta: [("off", 900), ("ino", 43)])
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try store.totals(forDayEpoch: DayBucket.dayEpoch(for: t))[.aiInputTokens], 300)
        XCTAssertEqual(try store.metaInt("off"), 900)
        XCTAssertEqual(try store.metaInt("ino"), 43)
    }

    func testIngestRecordsFirstSeenDayNotEventDayForPruning() throws {
        // A sample whose event day is far older than the 45-day retention window.
        let oldTimestamp = date(dayOffset: -100, minute: 0)
        do {
            let store = try SampleStore(path: dbPath)
            let recorded = try store.ingest(
                events: [AIIngestEvent(dedupKey: "old-key",
                                       samples: [Sample(kind: .aiInputTokens, value: 5, timestamp: oldTimestamp)])],
                meta: []
            )
            XCTAssertEqual(recorded.count, 1)
        }

        // Reopening prunes ai_seen by first-seen day. The key was first seen "today", so it survives
        // despite the 100-day-old sample timestamp; the re-ingest is therefore still deduped.
        let store = try SampleStore(path: dbPath)
        let again = try store.ingest(
            events: [AIIngestEvent(dedupKey: "old-key",
                                   samples: [Sample(kind: .aiInputTokens, value: 5, timestamp: oldTimestamp)])],
            meta: []
        )
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try store.totals(forDayEpoch: DayBucket.dayEpoch(for: oldTimestamp))[.aiInputTokens], 5)
    }

    func testMetaKeysWithPrefixAndDeleteMeta() throws {
        let store = try SampleStore(path: dbPath)
        try store.setMetaInt("ai.claudeCode.offset:/a.jsonl", 1)
        try store.setMetaInt("ai.claudeCode.inode:/a.jsonl", 2)
        try store.setMetaInt("net.baseline.en0", 3)

        let keys = try store.metaKeys(withPrefix: "ai.claudeCode.").sorted()
        XCTAssertEqual(keys, ["ai.claudeCode.inode:/a.jsonl", "ai.claudeCode.offset:/a.jsonl"])

        try store.deleteMeta(key: "ai.claudeCode.offset:/a.jsonl")
        XCTAssertNil(try store.metaInt("ai.claudeCode.offset:/a.jsonl"))
        XCTAssertEqual(try store.metaInt("ai.claudeCode.inode:/a.jsonl"), 2)
        // The unrelated key was never matched by the prefix and is untouched.
        XCTAssertEqual(try store.metaInt("net.baseline.en0"), 3)
    }

    func testPruneRemovesOldKeepsRecent() throws {
        let store = try SampleStore(path: dbPath)
        let today = DayBucket.dayEpoch(for: Date())
        let old = today - 40 * 86_400
        let recent = today - 2 * 86_400
        XCTAssertTrue(try store.markSeen(dedupKey: "old", dayEpoch: old))
        XCTAssertTrue(try store.markSeen(dedupKey: "recent", dayEpoch: recent))

        store.pruneAISeen(olderThanDays: 30)

        // The old entry was dropped, so re-marking it inserts anew (true); the recent one survives (false).
        XCTAssertTrue(try store.markSeen(dedupKey: "old", dayEpoch: old))
        XCTAssertFalse(try store.markSeen(dedupKey: "recent", dayEpoch: recent))
    }
}
