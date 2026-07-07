import XCTest
import SQLite3
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
        let t2 = t.addingTimeInterval(120)   // same session, two minutes later
        let day = DayBucket.dayEpoch(for: t)
        func attr(_ ts: Date) -> AIUsageAttribution {
            AIUsageAttribution(source: "claudeCode", model: "claude", sessionId: "sess1", timestamp: ts)
        }
        let events = [
            AIIngestEvent(dedupKey: "k1", samples: [Sample(kind: .aiInputTokens, value: 100, timestamp: t)],
                          attribution: attr(t)),
            AIIngestEvent(dedupKey: "k2", samples: [Sample(kind: .aiInputTokens, value: 200, timestamp: t2)],
                          attribution: attr(t2)),
        ]
        let recorded = try store.ingest(events: events, meta: [("off", 500), ("ino", 42)])

        // Every effect landed together in the one transaction: samples, meta offsets, the per-model
        // day total, and the session's first/last bounds.
        XCTAssertEqual(recorded.reduce(0) { $0 + $1.value }, 300)
        XCTAssertEqual(try store.totals(forDayEpoch: day)[.aiInputTokens], 300)
        XCTAssertEqual(try store.metaInt("off"), 500)
        XCTAssertEqual(try store.metaInt("ino"), 42)
        let models = try store.aiModelTotals(dayEpoch: day)
        XCTAssertEqual(models.map(\.model), ["claude"])
        XCTAssertEqual(models.first?.input, 300)
        let sessions = try store.aiSessionStats(dayEpoch: day)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.longestLength, 120)

        // Re-ingesting the same keys records nothing new (dedup) but still advances the offset meta. The
        // model total and the session bounds are exactly-once too: they are gated on the newly-seen key,
        // so a retry never doubles them.
        let again = try store.ingest(events: events, meta: [("off", 900), ("ino", 43)])
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try store.totals(forDayEpoch: day)[.aiInputTokens], 300)
        XCTAssertEqual(try store.aiModelTotals(dayEpoch: day).first?.input, 300)
        XCTAssertEqual(try store.aiSessionStats(dayEpoch: day).count, 1)
        XCTAssertEqual(try store.metaInt("off"), 900)
        XCTAssertEqual(try store.metaInt("ino"), 43)
    }

    /// A genuine failure partway through `ingest` must roll the WHOLE batch back: no dedup key, no
    /// samples, no meta, no model row, no session row. The failure is induced by dropping `ai_models`
    /// from a second connection so the attributed upsert can no longer prepare inside the transaction.
    func testIngestRollsBackEntireBatchWhenAModelWriteFails() throws {
        let store = try SampleStore(path: dbPath)
        let t = date(dayOffset: 0, minute: 5)
        let day = DayBucket.dayEpoch(for: t)

        // Sabotage the schema out-of-band: drop the table the attributed ingest needs.
        var sabotage: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &sabotage, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let saboteur = try XCTUnwrap(sabotage)
        try execSQL(saboteur, "DROP TABLE ai_models;")
        sqlite3_close_v2(saboteur)

        let events = [AIIngestEvent(
            dedupKey: "doomed",
            samples: [Sample(kind: .aiInputTokens, value: 100, timestamp: t)],
            attribution: AIUsageAttribution(source: "codex", model: "gpt", sessionId: "s", timestamp: t)
        )]
        XCTAssertThrowsError(try store.ingest(events: events, meta: [("off", 500)]))

        // Nothing from the failed batch persisted: the key is still unseen, no samples, no meta.
        XCTAssertTrue(try store.totals(forDayEpoch: day).isEmpty)
        XCTAssertNil(try store.metaInt("off"))
        XCTAssertTrue(try store.markSeen(dedupKey: "doomed", dayEpoch: day))
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

    func testMinuteSeriesCrossesMidnightWithZerosAndExcludesInProgressMinute() throws {
        let store = try SampleStore(path: dbPath)
        let todayMidnight = Calendar.current.startOfDay(for: Date())

        // Build both days off `todayMidnight` by second-offset, the same way the query walks back one
        // minute at a time, so the alignment holds regardless of any DST oddity on the boundary day.
        func at(minutesFromMidnight m: Int, second: Int = 15) -> Date {
            todayMidnight.addingTimeInterval(TimeInterval(m * 60 + second))
        }

        try store.record([
            // Today's head.
            Sample(kind: .networkBytesIn, value: 100, timestamp: at(minutesFromMidnight: 0)),
            Sample(kind: .networkBytesIn, value: 200, timestamp: at(minutesFromMidnight: 1)),
            Sample(kind: .networkBytesIn, value: 300, timestamp: at(minutesFromMidnight: 2)),
            Sample(kind: .networkBytesIn, value: 400, timestamp: at(minutesFromMidnight: 3)),
            Sample(kind: .networkBytesIn, value: 500, timestamp: at(minutesFromMidnight: 4)),
            // The reference's own minute (5) is still in progress and must be excluded.
            Sample(kind: .networkBytesIn, value: 999, timestamp: at(minutesFromMidnight: 5)),
            // Yesterday's tail: 23:59 (-1) and 23:55 (-5), with gaps between that must read as zero.
            Sample(kind: .networkBytesIn, value: 700, timestamp: at(minutesFromMidnight: -1)),
            Sample(kind: .networkBytesIn, value: 600, timestamp: at(minutesFromMidnight: -5)),
        ])

        let reference = at(minutesFromMidnight: 5, second: 30)
        let series = try store.minuteSeries(kinds: [.networkBytesIn], count: 10, endingBefore: reference)

        // Oldest first: [23:55, 23:56, 23:57, 23:58, 23:59, 00:00, 00:01, 00:02, 00:03, 00:04].
        XCTAssertEqual(series[.networkBytesIn], [600, 0, 0, 0, 700, 100, 200, 300, 400, 500])
    }

    func testMinuteSeriesReturnsZerosForAnEmptyWindow() throws {
        let store = try SampleStore(path: dbPath)
        let series = try store.minuteSeries(
            kinds: [.inputKeystrokes, .diskBytesRead], count: 5, endingBefore: Date()
        )
        XCTAssertEqual(series[.inputKeystrokes], [0, 0, 0, 0, 0])
        XCTAssertEqual(series[.diskBytesRead], [0, 0, 0, 0, 0])
    }

    func testHourlySeriesBucketsMinutesIntoTwentyFourHoursAcrossBoundaries() throws {
        let store = try SampleStore(path: dbPath)
        let day = DayBucket.dayEpoch(for: date(dayOffset: 0, minute: 0))
        try store.record([
            Sample(kind: .networkBytesIn, value: 10, timestamp: date(dayOffset: 0, minute: 0)),    // hour 0
            Sample(kind: .networkBytesIn, value: 5, timestamp: date(dayOffset: 0, minute: 59)),     // hour 0
            Sample(kind: .networkBytesIn, value: 100, timestamp: date(dayOffset: 0, minute: 60)),   // hour 1
            Sample(kind: .networkBytesIn, value: 3, timestamp: date(dayOffset: 0, minute: 119)),    // hour 1
            Sample(kind: .networkBytesIn, value: 7, timestamp: date(dayOffset: 0, minute: 1439)),   // hour 23
            Sample(kind: .diskBytesRead, value: 42, timestamp: date(dayOffset: 0, minute: 61)),     // hour 1
        ])

        let series = try store.hourlySeries(kinds: [.networkBytesIn, .diskBytesRead], dayEpoch: day)

        let net = try XCTUnwrap(series[.networkBytesIn])
        XCTAssertEqual(net.count, 24)
        XCTAssertEqual(net[0], 15)   // 10 + 5 both in the first hour
        XCTAssertEqual(net[1], 103)  // 100 + 3 straddle minutes 60 and 119
        XCTAssertEqual(net[23], 7)   // minute 1439 is the last hour
        XCTAssertEqual(net.reduce(0, +), 125)

        let disk = try XCTUnwrap(series[.diskBytesRead])
        XCTAssertEqual(disk[1], 42)
        XCTAssertEqual(disk[0], 0)
    }

    func testHourlySeriesEmptyDayAndAbsentKindsReadAsTwentyFourZeros() throws {
        let store = try SampleStore(path: dbPath)
        let day = DayBucket.dayEpoch(for: date(dayOffset: 0, minute: 30))
        try store.record([
            Sample(kind: .inputKeystrokes, value: 9, timestamp: date(dayOffset: 0, minute: 30)), // hour 0
            // A sample on the next day must not leak into this day's buckets.
            Sample(kind: .inputKeystrokes, value: 4, timestamp: date(dayOffset: 1, minute: 30)),
        ])

        let series = try store.hourlySeries(kinds: [.inputKeystrokes, .aiOutputTokens], dayEpoch: day)
        XCTAssertEqual(series[.inputKeystrokes]?[0], 9)
        XCTAssertEqual(series[.inputKeystrokes]?.reduce(0, +), 9)
        // A requested kind with no rows on the day is present as 24 zeros, never missing.
        XCTAssertEqual(series[.aiOutputTokens], Array(repeating: 0, count: 24))

        // A day with no rows at all is 24 zeros for every requested kind.
        let empty = DayBucket.dayEpoch(for: date(dayOffset: 5, minute: 0))
        XCTAssertEqual(try store.hourlySeries(kinds: [.aiInputTokens], dayEpoch: empty),
                       [.aiInputTokens: Array(repeating: 0, count: 24)])
        // No kinds requested returns an empty result.
        XCTAssertTrue(try store.hourlySeries(kinds: [], dayEpoch: day).isEmpty)
    }

    func testDayMinuteSeriesReturnsOneKindsMinutesAscending() throws {
        let store = try SampleStore(path: dbPath)
        let day = DayBucket.dayEpoch(for: date(dayOffset: 0, minute: 0))
        try store.record([
            Sample(kind: .inputKeystrokes, value: 40, timestamp: date(dayOffset: 0, minute: 5)),
            // Same minute, different second: accumulates into one cell.
            Sample(kind: .inputKeystrokes, value: 10, timestamp: date(dayOffset: 0, minute: 5, second: 30)),
            Sample(kind: .inputKeystrokes, value: 84, timestamp: date(dayOffset: 0, minute: 9)),
            Sample(kind: .inputKeystrokes, value: 12, timestamp: date(dayOffset: 0, minute: 100)),
            // A different kind on the same day must not leak in.
            Sample(kind: .inputClicks, value: 999, timestamp: date(dayOffset: 0, minute: 9)),
            // A different day must not leak in.
            Sample(kind: .inputKeystrokes, value: 5, timestamp: date(dayOffset: 1, minute: 9)),
        ])

        // Ascending by minute; minute 5 accumulated 40 + 10 = 50. Only this kind, only this day.
        XCTAssertEqual(try store.dayMinuteSeries(kind: .inputKeystrokes, dayEpoch: day), [50, 84, 12])

        // A day/kind with no rows reads as an empty series.
        let empty = DayBucket.dayEpoch(for: date(dayOffset: 3, minute: 0))
        XCTAssertTrue(try store.dayMinuteSeries(kind: .inputKeystrokes, dayEpoch: empty).isEmpty)
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

    // MARK: - AI model & session ledgers

    /// Ingests an attributed event whose day is `dayOffset`, session `sessionId`, spanning `spanSeconds`.
    private func ingestAI(
        into store: SampleStore, key: String, dayOffset: Int, minute: Int, source: String,
        model: String, sessionId: String, input: Int64, output: Int64 = 0, spanSeconds: Int = 0
    ) throws {
        let start = date(dayOffset: dayOffset, minute: minute)
        var samples = [Sample(kind: .aiInputTokens, value: input, timestamp: start)]
        if output != 0 { samples.append(Sample(kind: .aiOutputTokens, value: output, timestamp: start)) }
        try store.ingest(
            events: [AIIngestEvent(dedupKey: key + ":a", samples: samples,
                attribution: AIUsageAttribution(source: source, model: model, sessionId: sessionId, timestamp: start))],
            meta: []
        )
        if spanSeconds > 0 {
            // A later event in the SAME session extends its last_seen without opening a new session.
            let end = start.addingTimeInterval(TimeInterval(spanSeconds))
            try store.ingest(
                events: [AIIngestEvent(dedupKey: key + ":b",
                    samples: [Sample(kind: .aiOutputTokens, value: 1, timestamp: end)],
                    attribution: AIUsageAttribution(source: source, model: model, sessionId: sessionId, timestamp: end))],
                meta: []
            )
        }
    }

    func testAIModelTotalsGroupByModelSingleDayAndAcrossDays() throws {
        let store = try SampleStore(path: dbPath)
        // Day 0: two Claude models plus a Codex model.
        try ingestAI(into: store, key: "d0-a", dayOffset: 0, minute: 10, source: "claudeCode", model: "opus", sessionId: "s1", input: 100, output: 40)
        try ingestAI(into: store, key: "d0-b", dayOffset: 0, minute: 11, source: "claudeCode", model: "opus", sessionId: "s1", input: 50)
        try ingestAI(into: store, key: "d0-c", dayOffset: 0, minute: 12, source: "claudeCode", model: "haiku", sessionId: "s2", input: 5)
        try ingestAI(into: store, key: "d0-d", dayOffset: 0, minute: 13, source: "codex", model: "gpt", sessionId: "s3", input: 200)
        // Day 1: more opus.
        try ingestAI(into: store, key: "d1-a", dayOffset: 1, minute: 10, source: "claudeCode", model: "opus", sessionId: "s4", input: 300)

        let day0 = DayBucket.dayEpoch(for: date(dayOffset: 0, minute: 0))
        let day1 = DayBucket.dayEpoch(for: date(dayOffset: 1, minute: 0))
        let single = try store.aiModelTotals(dayEpoch: day0)
        // Heaviest first: codex/gpt (200) then claudeCode/opus (150+40) then claudeCode/haiku (5).
        XCTAssertEqual(single.map(\.model), ["gpt", "opus", "haiku"])
        XCTAssertEqual(single.first { $0.model == "opus" }?.input, 150)
        XCTAssertEqual(single.first { $0.model == "opus" }?.output, 40)

        // Across both days the two opus rows collapse into one grouped total (150 + 300 input).
        let across = try store.aiModelTotals(dayEpochs: [day0, day1])
        XCTAssertEqual(across.first { $0.source == "claudeCode" && $0.model == "opus" }?.input, 450)
        XCTAssertEqual(across.filter { $0.model == "opus" }.count, 1)
    }

    func testAISessionStatsCountsSessionsByFirstSeenDay() throws {
        let store = try SampleStore(path: dbPath)
        // Two sessions open on day 0: one spanning 300 s, one a single instant (length 0).
        try ingestAI(into: store, key: "s-a", dayOffset: 0, minute: 10, source: "codex", model: "gpt", sessionId: "sA", input: 10, spanSeconds: 300)
        try ingestAI(into: store, key: "s-b", dayOffset: 0, minute: 20, source: "codex", model: "gpt", sessionId: "sB", input: 10)
        // One session opens on day 1.
        try ingestAI(into: store, key: "s-c", dayOffset: 1, minute: 10, source: "codex", model: "gpt", sessionId: "sC", input: 10, spanSeconds: 100)

        let day0 = DayBucket.dayEpoch(for: date(dayOffset: 0, minute: 0))
        let stats0 = try store.aiSessionStats(dayEpoch: day0)
        XCTAssertEqual(stats0.count, 2)
        XCTAssertEqual(stats0.longestLength, 300)
        XCTAssertEqual(stats0.averageLength, 150)   // (300 + 0) / 2

        let day1 = DayBucket.dayEpoch(for: date(dayOffset: 1, minute: 0))
        XCTAssertEqual(try store.aiSessionStats(dayEpoch: day1).count, 1)

        // A day with no sessions reports zeros, never a nil.
        let emptyDay = DayBucket.dayEpoch(for: date(dayOffset: 5, minute: 0))
        XCTAssertEqual(try store.aiSessionStats(dayEpoch: emptyDay), AISessionStats(count: 0, averageLength: 0, longestLength: 0))
    }

    // MARK: - Gauges

    func testRecordGaugeReplacesAndSeriesLeavesGapsNil() throws {
        let store = try SampleStore(path: dbPath)
        let day = DayBucket.dayEpoch(for: date(dayOffset: 0, minute: 0))
        try store.recordGauge(dayEpoch: day, minute: 5, gauge: "cpuTemperature", value: 400)
        // A gauge is a reading, not an accumulator: a second write to the same cell REPLACES it.
        try store.recordGauge(dayEpoch: day, minute: 5, gauge: "cpuTemperature", value: 455)
        try store.recordGauge(dayEpoch: day, minute: 9, gauge: "cpuTemperature", value: 0)   // zero is a real reading
        // A different gauge in the same minute is independent.
        try store.recordGauge(dayEpoch: day, minute: 5, gauge: "fanRPM", value: 1200)

        let temps = try store.gaugeSeries(gauge: "cpuTemperature", dayEpoch: day)
        XCTAssertEqual(temps.count, 1440)
        XCTAssertEqual(temps[5], 455)         // replaced, not summed to 855
        XCTAssertEqual(temps[9], 0)           // zero reading is present, distinct from a gap
        XCTAssertNil(temps[6])                // an untouched minute is honestly absent
        XCTAssertEqual(try store.gaugeSeries(gauge: "fanRPM", dayEpoch: day)[5], 1200)

        // Out-of-range minutes are a no-op, and an unread gauge is all nils.
        try store.recordGauge(dayEpoch: day, minute: 1440, gauge: "cpuTemperature", value: 999)
        XCTAssertEqual(try store.gaugeSeries(gauge: "ambientLux", dayEpoch: day), Array(repeating: nil, count: 1440))
    }
}
