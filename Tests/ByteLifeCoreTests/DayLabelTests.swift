import XCTest
@testable import ByteLifeCore

final class DayLabelTests: XCTestCase {
    /// A fixed UTC Gregorian calendar so the labels are asserted against wall-clock dates independent of
    /// the machine's time zone.
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The day epoch (local midnight, here UTC) for a year/month/day.
    private func epoch(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day))!
        return Int64(date.timeIntervalSince1970)
    }

    func testShortIsAbbreviatedMonthAndDay() {
        XCTAssertEqual(DayLabel.short(dayEpoch: epoch(2026, 7, 7), calendar: utc), "Jul 7")
        XCTAssertEqual(DayLabel.short(dayEpoch: epoch(2024, 1, 1), calendar: utc), "Jan 1")
        XCTAssertEqual(DayLabel.short(dayEpoch: epoch(2025, 12, 25), calendar: utc), "Dec 25")
    }

    func testFullIsWeekdayMonthDayYear() {
        XCTAssertEqual(DayLabel.full(dayEpoch: epoch(2026, 7, 7), calendar: utc), "Tuesday, July 7, 2026")
        XCTAssertEqual(DayLabel.full(dayEpoch: epoch(2024, 1, 1), calendar: utc), "Monday, January 1, 2024")
    }
}
