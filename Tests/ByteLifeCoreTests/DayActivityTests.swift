import XCTest
@testable import ByteLifeCore

final class DayActivityTests: XCTestCase {
    private let d1: Int64 = 1_000
    private let d2: Int64 = 2_000
    private let d3: Int64 = 3_000

    func testRowsAreNewestFirstWithTokensBytesAndNormalizedFractions() {
        let totalsByDay: [Int64: [MetricKind: Int64]] = [
            // tokens 200, bytes 40 (all four traffic/storage kinds)
            d1: [.aiInputTokens: 100, .aiOutputTokens: 100,
                 .networkBytesIn: 10, .networkBytesOut: 10, .diskBytesRead: 10, .diskBytesWritten: 10],
            // tokens 400 (the max), bytes 5
            d2: [.aiInputTokens: 300, .aiOutputTokens: 100, .networkBytesIn: 5],
            // tokens 0, bytes 60 (the max)
            d3: [.diskBytesWritten: 60],
        ]
        // Input order is deliberately scrambled; the rows must still sort newest-first.
        let rows = DayActivity.rows(daysWithData: [d1, d3, d2], totalsByDay: totalsByDay)
        XCTAssertEqual(rows.map(\.dayEpoch), [d3, d2, d1])

        let r2 = try! XCTUnwrap(rows.first { $0.dayEpoch == d2 })
        XCTAssertEqual(r2.tokens, 400)
        XCTAssertEqual(r2.bytes, 5)
        XCTAssertEqual(r2.tokenFraction, 1.0, accuracy: 1e-9)      // largest token day
        XCTAssertEqual(r2.byteFraction, 5.0 / 60.0, accuracy: 1e-9)

        let r1 = try! XCTUnwrap(rows.first { $0.dayEpoch == d1 })
        XCTAssertEqual(r1.tokens, 200)
        XCTAssertEqual(r1.bytes, 40)
        XCTAssertEqual(r1.tokenFraction, 200.0 / 400.0, accuracy: 1e-9)
        XCTAssertEqual(r1.byteFraction, 40.0 / 60.0, accuracy: 1e-9)

        let r3 = try! XCTUnwrap(rows.first { $0.dayEpoch == d3 })
        XCTAssertEqual(r3.tokens, 0)
        XCTAssertEqual(r3.bytes, 60)
        XCTAssertEqual(r3.tokenFraction, 0.0, accuracy: 1e-9)      // no tokens that day
        XCTAssertEqual(r3.byteFraction, 1.0, accuracy: 1e-9)       // largest byte day
    }

    func testFractionsAreZeroWhenTheMaximumIsZero() {
        let rows = DayActivity.rows(daysWithData: [d1], totalsByDay: [d1: [:]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tokens, 0)
        XCTAssertEqual(rows[0].bytes, 0)
        XCTAssertEqual(rows[0].tokenFraction, 0)
        XCTAssertEqual(rows[0].byteFraction, 0)
    }

    func testEmptyDayListYieldsNoRows() {
        XCTAssertTrue(DayActivity.rows(daysWithData: [], totalsByDay: [:]).isEmpty)
    }

    func testDaysMissingFromTotalsCountAsZero() {
        let rows = DayActivity.rows(daysWithData: [d1, d2], totalsByDay: [d2: [.aiInputTokens: 10]])
        let r1 = try! XCTUnwrap(rows.first { $0.dayEpoch == d1 })
        XCTAssertEqual(r1.tokens, 0)
        XCTAssertEqual(r1.tokenFraction, 0)
        let r2 = try! XCTUnwrap(rows.first { $0.dayEpoch == d2 })
        XCTAssertEqual(r2.tokens, 10)
        XCTAssertEqual(r2.tokenFraction, 1.0, accuracy: 1e-9)
    }
}
