import XCTest
@testable import ByteLifeCore

final class DayStoryTests: XCTestCase {
    /// A 24-slot hourly array with the given hour->value pairs set and every other hour zero.
    private func hours(_ pairs: [Int: Int64]) -> [Int64] {
        var a = [Int64](repeating: 0, count: 24)
        for (hour, value) in pairs { a[hour] = value }
        return a
    }

    /// A fully populated day exercising every account's hourly combination, headline, and figure rows.
    private func fullStory() -> DayStory {
        let hourly: [MetricKind: [Int64]] = [
            .aiInputTokens: hours([0: 100, 5: 50]),   // 150 prompted
            .aiOutputTokens: hours([0: 400, 5: 200]), // 600 generated
            .networkBytesIn: hours([1: 1_048_576]),   // 1 MB in
            .networkBytesOut: hours([1: 1_024]),      // 1 KB out
            .diskBytesRead: hours([2: 1_536]),        // 1.5 KB read
            .diskBytesWritten: hours([2: 512]),       // 512 B written
            .screenAttentiveSeconds: hours([3: 24_120]), // 06:42
            .inputKeystrokes: hours([4: 8_000]),
        ]
        let totals: [MetricKind: Int64] = [
            .aiInputTokens: 150, .aiOutputTokens: 600,
            .aiCacheCreationTokens: 300, .aiCacheReadTokens: 700,
            .networkBytesIn: 1_048_576, .networkBytesOut: 1_024,
            .diskBytesRead: 1_536, .diskBytesWritten: 512,
            .screenAttentiveSeconds: 24_120,
            .inputKeystrokes: 8_000, .inputMouseMilliPixels: 10_400_000,
        ]
        return DayStory.build(dayEpoch: 1_704_067_200, totals: totals, hourly: hourly)
    }

    func testCardsAreInCanonicalOrder() {
        XCTAssertEqual(fullStory().cards.map(\.kind), [.token, .traffic, .storage, .hours, .labor])
    }

    func testTokenCardCombinesHourlyHeadlineAndReusesSheetLines() {
        let token = fullStory().cards[0]
        // Hourly is AI input plus output per hour.
        XCTAssertEqual(token.hourly[0], 500) // 100 + 400
        XCTAssertEqual(token.hourly[5], 250) // 50 + 200
        XCTAssertEqual(token.hourly.reduce(0, +), 750)
        XCTAssertEqual(token.headline, ByteFormatting.tokens(750)) // "750"
        // Figure rows are the day sheet's token lines verbatim, including the exchange and cache memos.
        XCTAssertEqual(token.lines.map(\.label),
                       ["Tokens Payable", "Tokens Receivable", "Exchange rate", "Cache"])
        XCTAssertEqual(token.lines[0].value, "150")
        XCTAssertEqual(token.lines[0].side, .debit)
        XCTAssertEqual(token.lines[1].value, "600")
        XCTAssertEqual(token.lines[1].side, .credit)
        XCTAssertEqual(token.lines[2].value, "4.00 : 1") // 600 / 150
        XCTAssertEqual(token.lines[3].value, "300 w / 700 r")
    }

    func testTrafficAndStorageCardsCombineBothChannels() {
        let story = fullStory()
        let traffic = story.cards[1]
        XCTAssertEqual(traffic.hourly[1], 1_049_600) // 1 MB in + 1 KB out
        XCTAssertEqual(traffic.headline, ByteFormatting.bytes(1_049_600))
        XCTAssertEqual(traffic.lines.map(\.label), ["Bytes Remitted", "Bytes Received", "Net flow"])

        let storage = story.cards[2]
        XCTAssertEqual(storage.hourly[2], 2_048) // 1536 read + 512 written
        XCTAssertEqual(storage.headline, ByteFormatting.bytes(2_048)) // "2.0 KB"
        XCTAssertEqual(storage.lines.map(\.label), ["Writes Posted", "Reads Drawn", "Churn"])
    }

    func testHoursCardAddsPercentOfDayAndLaborCarriesDistance() {
        let story = fullStory()
        let hoursCard = story.cards[3]
        XCTAssertEqual(hoursCard.hourly[3], 24_120)
        XCTAssertEqual(hoursCard.headline, "06:42")
        XCTAssertEqual(hoursCard.lines.map(\.label), ["Attention", "Percent of day"])
        XCTAssertEqual(hoursCard.lines[0].value, "06:42")
        XCTAssertEqual(hoursCard.lines[0].side, .debit)
        XCTAssertEqual(hoursCard.lines[1].value, "27.9%") // 24120 / 864
        XCTAssertEqual(hoursCard.lines[1].side, .memo)

        let labor = story.cards[4]
        XCTAssertEqual(labor.hourly[4], 8_000)
        XCTAssertEqual(labor.headline, "8,000")
        XCTAssertEqual(labor.lines.map(\.label), ["Keys Struck", "Distance Hauled"])
        XCTAssertEqual(labor.lines[1].value, ByteFormatting.distanceHauled(milliPixels: 10_400_000))
    }

    func testPostedByteVolumeAndHeroArraysAreExposedSeparately() {
        let story = fullStory()
        // Traffic churn (1_049_600) plus Storage churn (2_048).
        XCTAssertEqual(story.postedByteVolume, ByteFormatting.bytes(1_051_648))
        XCTAssertEqual(story.trafficHourly, story.cards[1].hourly)
        XCTAssertEqual(story.storageHourly, story.cards[2].hourly)
        XCTAssertEqual(story.trafficHourly[1], 1_049_600)
        XCTAssertEqual(story.storageHourly[2], 2_048)
    }

    func testEmptyDayIsStructurallyCompleteAndZeroed() {
        let story = DayStory.build(dayEpoch: 0, totals: [:], hourly: [:])
        XCTAssertEqual(story.cards.count, 5)
        XCTAssertTrue(story.cards.allSatisfy { $0.hourly == Array(repeating: 0, count: 24) })
        XCTAssertEqual(story.cards[0].headline, "0")     // tokens
        XCTAssertEqual(story.cards[1].headline, "0 B")   // traffic
        XCTAssertEqual(story.cards[3].headline, "00:00") // hours
        XCTAssertEqual(story.cards[4].headline, "0")     // labor keys
        XCTAssertEqual(story.cards[3].lines.last?.value, "0.0%")
        XCTAssertEqual(story.postedByteVolume, "0 B")
        XCTAssertEqual(story.trafficHourly, Array(repeating: 0, count: 24))
        // With nothing prompted the exchange rate is undefined, printed "n/a".
        XCTAssertEqual(story.cards[0].lines.first { $0.label == "Exchange rate" }?.value, "n/a")
    }

    func testHourlyKindsCoverEveryAccountChannelExactly() {
        XCTAssertEqual(Set(DayStory.hourlyKinds), Set([
            .aiInputTokens, .aiOutputTokens, .networkBytesIn, .networkBytesOut,
            .diskBytesRead, .diskBytesWritten, .screenAttentiveSeconds, .inputKeystrokes,
        ]))
    }
}
