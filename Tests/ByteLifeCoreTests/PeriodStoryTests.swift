import XCTest
@testable import ByteLifeCore

final class PeriodStoryTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func epoch(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        Int64(utc.date(from: DateComponents(year: year, month: month, day: day))!.timeIntervalSince1970)
    }

    /// Two days of a week: Jul 6 (heavy) and Jul 7 (light), with one day posted.
    private func weekStory() -> PeriodStory {
        let d6 = epoch(2026, 7, 6)
        let d7 = epoch(2026, 7, 7)
        let totalsByDay: [Int64: [MetricKind: Int64]] = [
            d6: [.aiInputTokens: 100, .aiOutputTokens: 400,
                 .aiCacheCreationTokens: 300, .aiCacheReadTokens: 700,
                 .networkBytesIn: 1_048_576, .networkBytesOut: 1_024,
                 .diskBytesRead: 1_536, .diskBytesWritten: 512,
                 .screenAttentiveSeconds: 24_120,
                 .inputKeystrokes: 8_000, .inputMouseMilliPixels: 10_400_000],
            d7: [.aiInputTokens: 50, .aiOutputTokens: 200,
                 .networkBytesIn: 2_048, .diskBytesWritten: 256,
                 .screenAttentiveSeconds: 3_600, .inputKeystrokes: 1_000],
        ]
        return PeriodStory.build(
            label: "Week 28 · Jul 6–12",
            dayEpochs: [d7, d6],   // deliberately newest-first input; the story orders oldest-first
            totalsByDay: totalsByDay,
            stampsByDay: [d6: "BALANCED"],
            calendar: utc
        )
    }

    func testDaysAreOldestFirstWithDayOfMonthAndState() {
        let story = weekStory()
        XCTAssertEqual(story.days.map(\.dayEpoch), [epoch(2026, 7, 6), epoch(2026, 7, 7)])
        XCTAssertEqual(story.days.map(\.dayOfMonth), [6, 7])
        XCTAssertTrue(story.days[0].isPosted)      // Jul 6 BALANCED
        XCTAssertFalse(story.days[1].isPosted)     // Jul 7 open
    }

    func testCardsAreCanonicalOrderWithAggregateHeadlinesAndReusedLines() {
        let story = weekStory()
        XCTAssertEqual(story.cards.map(\.kind), [.token, .traffic, .storage, .hours, .labor])

        let token = story.cards[0]
        // Aggregate churn 750: (100+400) + (50+200).
        XCTAssertEqual(token.headline, ByteFormatting.tokens(750))
        // Figure rows are the day sheet's token lines over the sums, exchange rate 600/150 = 4.00 : 1.
        XCTAssertEqual(token.lines.map(\.label),
                       ["Tokens Payable", "Tokens Receivable", "Exchange rate", "Cache"])
        XCTAssertEqual(token.lines[0].value, "150")
        XCTAssertEqual(token.lines[1].value, "600")
        XCTAssertEqual(token.lines[2].value, "4.00 : 1")

        let traffic = story.cards[1]
        // 1_048_576 + 1_024 + 2_048 across both days.
        XCTAssertEqual(traffic.headline, ByteFormatting.bytes(1_051_648))
    }

    func testPerDayArraysAreAlignedOldestFirst() {
        let story = weekStory()
        let token = story.cards[0]
        XCTAssertEqual(token.perDay, [500, 250])       // Jul 6: 100+400, Jul 7: 50+200
        let hours = story.cards[3]
        XCTAssertEqual(hours.perDay, [24_120, 3_600])
        let labor = story.cards[4]
        XCTAssertEqual(labor.perDay, [8_000, 1_000])
        // The hero arrays are the traffic and storage cards' per-day series.
        XCTAssertEqual(story.trafficPerDay, story.cards[1].perDay)
        XCTAssertEqual(story.storagePerDay, story.cards[2].perDay)
        XCTAssertEqual(story.trafficPerDay, [1_049_600, 2_048])   // (1MB+1KB), (2KB)
        XCTAssertEqual(story.storagePerDay, [2_048, 256])         // (1536+512), (0+256)
    }

    func testPostedByteVolumeAndCoverage() {
        let story = weekStory()
        // Traffic churn 1_051_648 + Storage churn (2_048 + 256) = 1_053_952.
        XCTAssertEqual(story.postedByteVolume, ByteFormatting.bytes(1_053_952))
        XCTAssertEqual(story.postedCount, 1)
        XCTAssertEqual(story.dayCount, 2)
        XCTAssertFalse(story.fullyPosted)
        XCTAssertEqual(story.coverageText, "1 of 2 days posted")
    }

    func testFullyPostedCoverage() {
        let d6 = epoch(2026, 7, 6)
        let d7 = epoch(2026, 7, 7)
        let story = PeriodStory.build(
            label: "Week 28 · Jul 6–12",
            dayEpochs: [d6, d7],
            totalsByDay: [:],
            stampsByDay: [d6: "BALANCED", d7: "FLAGGED"],
            calendar: utc
        )
        XCTAssertEqual(story.postedCount, 2)
        XCTAssertTrue(story.fullyPosted)
        XCTAssertEqual(story.coverageText, "2 of 2 days posted")
    }

    func testEmptyPeriodIsStructurallyCompleteAndZeroed() {
        let d6 = epoch(2026, 7, 6)
        let story = PeriodStory.build(
            label: "Week 28 · Jul 6–12",
            dayEpochs: [d6],
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(story.cards.count, 5)
        XCTAssertTrue(story.cards.allSatisfy { $0.perDay == [0] })
        XCTAssertEqual(story.cards[0].headline, "0")     // tokens
        XCTAssertEqual(story.cards[1].headline, "0 B")   // traffic
        XCTAssertEqual(story.postedByteVolume, "0 B")
        XCTAssertEqual(story.postedCount, 0)
        XCTAssertEqual(story.coverageText, "0 of 1 days posted")
    }

    /// The period's notional AI cost is priced by the caller over the period's summed model rows and
    /// carried verbatim (equal to summing the daily figures, costs being linear in the token counts).
    func testAICostCarriesThePeriodSummary() throws {
        let d6 = epoch(2026, 7, 6)
        let d7 = epoch(2026, 7, 7)
        // haiku booked input on day 6 and output on day 7; the batched query returns their sums.
        let periodCost = PriceCard.bundled.cost(of: [
            AIModelTotal(source: "claudeCode", model: "claude-haiku-4-5",
                         input: 1_000_000, output: 1_000_000, cacheCreation: 0, cacheRead: 0),
            AIModelTotal(source: "codex", model: "mystery-9",
                         input: 300, output: 200, cacheCreation: 0, cacheRead: 0),
        ])
        let story = PeriodStory.build(
            label: "Week 28 · Jul 6–12",
            dayEpochs: [d7, d6],
            totalsByDay: [:],
            calendar: utc,
            aiCost: periodCost
        )
        let cost = try XCTUnwrap(story.aiCost)
        // haiku: $1.00 input plus $5.00 output; mystery stays unpriced and disclosed.
        XCTAssertEqual(PriceCard.dollars(cost.total), "$6.00")
        XCTAssertEqual(cost.unpricedTokens, 500)
    }

    /// Without a cost summary the period carries no cost, keeping the surfaces honestly off.
    func testAICostNilWhenNoneSupplied() {
        XCTAssertNil(weekStory().aiCost)
    }
}
