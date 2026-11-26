import Foundation
import XCTest
@testable import ByteLifeCore

final class LedgerHistoryTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func testDailyValuesKeepMissingDaysAndRecordedZeroSeparate() {
        let calendar = berlin
        let end = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 12))!
        let epochs = (0..<4).reversed().map { offset in
            DayBucket.dayEpoch(for: calendar.date(byAdding: .day, value: -offset, to: end)!, calendar: calendar)
        }
        let history = LedgerHistory(
            metric: LedgerModule.traffic.metrics[0],
            dayCount: 4, ending: end,
            totalsByDay: [
                epochs[0]: [.networkBytesIn: 40, .networkBytesOut: 2],
                epochs[1]: [.diskBytesRead: 300],
                epochs[3]: [.networkBytesOut: 0],
            ],
            calendar: calendar
        )

        XCTAssertEqual(history.days.map(\.dayEpoch), epochs)
        XCTAssertEqual(history.days.map(\.value), [42, nil, nil, 0])
        XCTAssertEqual(epochs[1] - epochs[0], 23 * 3600)
        XCTAssertEqual(history.weeks.count, 2)
        XCTAssertEqual(history.weeks[0].compactMap { $0?.dayEpoch }, [epochs[0]])
        XCTAssertEqual(history.weeks[0][6], history.days[0])
        XCTAssertEqual(history.weeks[1][0], history.days[1])
        XCTAssertEqual(history.weeks[1][2], history.days[3])
        XCTAssertNil(history.weeks[1][3])
    }

    func testMetricsKeepTheirOwnUnitsAndExcludeSeparateCacheRollups() {
        let cognition = LedgerModule.cognition.metrics
        XCTAssertEqual(cognition[0].value(in: [.aiInputTokens: 200, .aiOutputTokens: 100, .aiCacheReadTokens: 1_000]), 300)
        XCTAssertEqual(cognition[3].value(in: [.aiCacheReadTokens: 1_000]), 1_000)
        XCTAssertEqual(cognition[3].formatted(1_000), "1.0K tok")
        XCTAssertEqual(LedgerModule.exposure.metrics[0].formatted(4_200), "1h 10m")
        XCTAssertEqual(LedgerModule.other.metrics[0].formatted(12_400), "12.4 Wh")
    }
}
