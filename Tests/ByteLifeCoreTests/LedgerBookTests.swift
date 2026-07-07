import XCTest
@testable import ByteLifeCore

final class LedgerBookTests: XCTestCase {
    /// A UTC calendar over exact UTC-midnight epochs, so date and weekday labels are deterministic
    /// regardless of the machine running the tests.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // 2024-01-01 00:00:00 UTC, a Monday. Add whole days for consecutive UTC midnights.
    private let jan1: Int64 = 1_704_067_200
    private var jan2: Int64 { jan1 + 86_400 }  // Tuesday
    private var jan3: Int64 { jan1 + 172_800 } // Wednesday

    // MARK: - Periods

    func testPeriodsAreNewestFirstWithLabelsAndState() {
        let periods = LedgerPeriod.list(
            daysWithData: [jan1, jan2, jan3],
            stampsByDay: [jan1: "BALANCED", jan3: "FLAGGED"],
            calendar: utc
        )

        XCTAssertEqual(periods.map(\.dayEpoch), [jan3, jan2, jan1])
        XCTAssertEqual(periods[0].dateLabel, "2024-01-03")
        XCTAssertEqual(periods[0].weekday, "Wed")
        XCTAssertEqual(periods[0].state, .posted(stamp: "FLAGGED"))
        XCTAssertTrue(periods[0].isPosted)

        XCTAssertEqual(periods[1].dateLabel, "2024-01-02")
        XCTAssertEqual(periods[1].weekday, "Tue")
        XCTAssertEqual(periods[1].state, .unposted)
        XCTAssertFalse(periods[1].isPosted)

        XCTAssertEqual(periods[2].weekday, "Mon")
        XCTAssertEqual(periods[2].state, .posted(stamp: "BALANCED"))
    }

    func testPostedDayWithoutSamplesStillLists() {
        // A posted day whose samples are absent must still appear, via the union of the two day sets.
        let periods = LedgerPeriod.list(daysWithData: [], stampsByDay: [jan1: "BALANCED"], calendar: utc)
        XCTAssertEqual(periods.map(\.dayEpoch), [jan1])
        XCTAssertEqual(periods[0].state, .posted(stamp: "BALANCED"))
    }

    // MARK: - Trial balance

    func testTrialBalanceRowsFormatPerAccountUnit() {
        let totals: [MetricKind: Int64] = [
            .aiInputTokens: 1_000,
            .aiOutputTokens: 4_200,
            .networkBytesOut: 2_048,      // 2.0 KB
            .networkBytesIn: 1_048_576,   // 1.0 MB
            .diskBytesWritten: 512,
            .diskBytesRead: 1_536,        // 1.5 KB
            .screenAttentiveSeconds: 24_120, // 06:42
            .inputKeystrokes: 8_000,
            .inputMouseMilliPixels: 10_400_000, // ~1.2 m at 220 ppi
        ]
        let rows = TrialBalance.rows(totals: totals)

        XCTAssertEqual(rows.map(\.label),
                       ["Token Account", "Traffic Account", "Storage Account",
                        "Hours Under the Lamp", "Labor Account", "Distance Hauled"])

        XCTAssertEqual(rows[0].debit, "1,000")
        XCTAssertEqual(rows[0].credit, "4,200")

        XCTAssertEqual(rows[1].debit, "2.0 KB")
        XCTAssertEqual(rows[1].credit, "1.0 MB")

        XCTAssertEqual(rows[2].debit, "512 B")
        XCTAssertEqual(rows[2].credit, "1.5 KB")

        // Expense accounts book no credit.
        XCTAssertEqual(rows[3].debit, "06:42")
        XCTAssertEqual(rows[3].credit, "")
        XCTAssertEqual(rows[4].debit, "8,000")
        XCTAssertEqual(rows[4].credit, "")

        // Distance hauled is the indented Labor sub-line.
        XCTAssertTrue(rows[5].isSubline)
        XCTAssertEqual(rows[5].debit, ByteFormatting.distanceHauled(milliPixels: 10_400_000))
        XCTAssertEqual(rows[5].credit, "")
    }

    func testTrialBalanceOfEmptyDayIsAllZeros() {
        let rows = TrialBalance.rows(totals: [:])
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].debit, "0")
        XCTAssertEqual(rows[1].debit, "0 B")
        XCTAssertEqual(rows[3].debit, "00:00")
    }
}
