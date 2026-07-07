import XCTest
@testable import ByteLifeCore

final class PeriodGroupingTests: XCTestCase {
    /// A fixed UTC Gregorian calendar so week and month boundaries are asserted against wall-clock dates
    /// independent of the machine's time zone, mirroring `DayLabelTests`.
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The day epoch (UTC midnight) for a year/month/day.
    private func epoch(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day))!
        return Int64(date.timeIntervalSince1970)
    }

    // MARK: - Week boundaries

    func testWeekGroupsSplitAtTheMondaySundayBoundary() {
        // Jul 6 2026 is a Monday; Jul 12 is the Sunday closing that ISO week; Jul 13 opens the next.
        let mon = epoch(2026, 7, 6)
        let sun = epoch(2026, 7, 12)
        let nextMon = epoch(2026, 7, 13)
        let groups = PeriodGrouping.groups(
            daysWithData: [mon, sun, nextMon],
            granularity: .week,
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(groups.count, 2)
        // Newest first: the Jul 13 week leads.
        XCTAssertEqual(groups[0].dayEpochs, [nextMon])
        // Monday and Sunday of the same ISO week land together, newest first.
        XCTAssertEqual(groups[1].dayEpochs, [sun, mon])
    }

    func testWeekLabelIsIsoNumberAndMondaySundaySpan() {
        let groups = PeriodGrouping.groups(
            daysWithData: [epoch(2026, 7, 8)],   // a Wednesday inside the Jul 6–12 week
            granularity: .week,
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].label, "Week 28 · Jul 6–12")
    }

    func testWeekLabelStraddlingTwoMonthsNamesBoth() {
        // The ISO week holding Jul 1 2026 (a Wednesday) runs Mon Jun 29 to Sun Jul 5.
        let groups = PeriodGrouping.groups(
            daysWithData: [epoch(2026, 7, 1)],
            granularity: .week,
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(groups[0].label, "Week 27 · Jun 29–Jul 5")
    }

    func testIsoWeekNumberingAcrossAYearBoundary() {
        // Mon Dec 29 2025 belongs to ISO week 1 of 2026 (the week holding Jan 1 2026, a Thursday), and
        // Sun Dec 28 2025 closes ISO week 52 of 2025. They must fall in different week groups.
        let dec28 = epoch(2025, 12, 28)   // Sunday, ISO 2025-W52
        let dec29 = epoch(2025, 12, 29)   // Monday, ISO 2026-W01
        let jan1 = epoch(2026, 1, 1)      // Thursday, ISO 2026-W01
        let groups = PeriodGrouping.groups(
            daysWithData: [dec28, dec29, jan1],
            granularity: .week,
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(groups.count, 2)
        // Newest week first: the 2026-W01 group holds Dec 29 and Jan 1.
        XCTAssertEqual(groups[0].dayEpochs, [jan1, dec29])
        XCTAssertEqual(groups[0].label, "Week 01 · Dec 29–Jan 4")
        // The Dec 28 Sunday sits alone in the prior week.
        XCTAssertEqual(groups[1].dayEpochs, [dec28])
        XCTAssertEqual(groups[1].label, "Week 52 · Dec 22–28")
    }

    // MARK: - Month grouping

    func testMonthGroupingAndLabels() {
        let jul7 = epoch(2026, 7, 7)
        let jul20 = epoch(2026, 7, 20)
        let aug3 = epoch(2026, 8, 3)
        let groups = PeriodGrouping.groups(
            daysWithData: [jul7, aug3, jul20],
            granularity: .month,
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].label, "August 2026")
        XCTAssertEqual(groups[0].dayEpochs, [aug3])
        XCTAssertEqual(groups[1].label, "July 2026")
        XCTAssertEqual(groups[1].dayEpochs, [jul20, jul7])   // newest first within the month
    }

    func testDayGranularityLabelsMatchDayLabel() {
        let groups = PeriodGrouping.groups(
            daysWithData: [epoch(2026, 7, 7)],
            granularity: .day,
            totalsByDay: [:],
            calendar: utc
        )
        XCTAssertEqual(groups[0].label, DayLabel.short(dayEpoch: epoch(2026, 7, 7), calendar: utc))
        XCTAssertEqual(groups[0].label, "Jul 7")
        XCTAssertEqual(groups[0].dayCount, 1)
    }

    // MARK: - Aggregates, coverage, and normalization

    func testAggregateSumsAndCoverageAcrossAWeek() {
        let mon = epoch(2026, 7, 6)
        let tue = epoch(2026, 7, 7)
        let totalsByDay: [Int64: [MetricKind: Int64]] = [
            // tokens 300 (100 + 200), bytes 40 (all four byte kinds)
            mon: [.aiInputTokens: 100, .aiOutputTokens: 200,
                  .networkBytesIn: 10, .networkBytesOut: 10, .diskBytesRead: 10, .diskBytesWritten: 10],
            // tokens 50, bytes 6
            tue: [.aiOutputTokens: 50, .networkBytesIn: 6],
        ]
        let groups = PeriodGrouping.groups(
            daysWithData: [mon, tue],
            granularity: .week,
            totalsByDay: totalsByDay,
            stampsByDay: [mon: "BALANCED"],
            calendar: utc
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tokens, 350)   // 300 + 50
        XCTAssertEqual(groups[0].bytes, 46)     // 40 + 6
        XCTAssertEqual(groups[0].postedCount, 1)
        XCTAssertEqual(groups[0].dayCount, 2)
        XCTAssertFalse(groups[0].fullyPosted)
        // Only one period, so it is the maximum on both axes.
        XCTAssertEqual(groups[0].tokenFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(groups[0].byteFraction, 1.0, accuracy: 1e-9)
    }

    func testFractionsNormalizeAcrossListedMonths() {
        let jul = epoch(2026, 7, 10)
        let aug = epoch(2026, 8, 10)
        let totalsByDay: [Int64: [MetricKind: Int64]] = [
            jul: [.aiInputTokens: 100, .networkBytesIn: 100],   // tokens 100, bytes 100 (the max both)
            aug: [.aiInputTokens: 25, .networkBytesIn: 40],     // tokens 25, bytes 40
        ]
        let groups = PeriodGrouping.groups(
            daysWithData: [jul, aug],
            granularity: .month,
            totalsByDay: totalsByDay,
            calendar: utc
        )
        let julGroup = try! XCTUnwrap(groups.first { $0.label == "July 2026" })
        let augGroup = try! XCTUnwrap(groups.first { $0.label == "August 2026" })
        XCTAssertEqual(julGroup.tokenFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(julGroup.byteFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(augGroup.tokenFraction, 25.0 / 100.0, accuracy: 1e-9)
        XCTAssertEqual(augGroup.byteFraction, 40.0 / 100.0, accuracy: 1e-9)
    }

    func testFullyPostedWhenEveryMemberIsStamped() {
        let mon = epoch(2026, 7, 6)
        let tue = epoch(2026, 7, 7)
        let groups = PeriodGrouping.groups(
            daysWithData: [mon, tue],
            granularity: .week,
            totalsByDay: [:],
            stampsByDay: [mon: "BALANCED", tue: "FLAGGED"],
            calendar: utc
        )
        XCTAssertEqual(groups[0].postedCount, 2)
        XCTAssertTrue(groups[0].fullyPosted)
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(PeriodGrouping.groups(
            daysWithData: [], granularity: .week, totalsByDay: [:], calendar: utc).isEmpty)
        XCTAssertTrue(PeriodGrouping.groups(
            daysWithData: [], granularity: .month, totalsByDay: [:], calendar: utc).isEmpty)
    }
}
