import XCTest
@testable import ByteLifeCore

final class MarginNotesTests: XCTestCase {
    private func mb(_ n: Int64) -> Int64 { n * 1024 * 1024 }

    func testVarianceRuleFiresAndReportsPercentUp() {
        // Network churn quadruples against a flat trailing average.
        let trailing = Array(repeating: [MetricKind.networkBytesIn: mb(100)], count: 3)
        let today: [MetricKind: Int64] = [.networkBytesIn: mb(500)]
        let note = MarginNotes.note(today: today, trailing: trailing)
        XCTAssertEqual(note.rule, .variance)
        XCTAssertEqual(note.text, "Network traffic up 400% versus the trailing average. No judgment. Filing it.")
    }

    func testVarianceDownDirectionAndDeterministicTieBreak() {
        // Both network and storage collapse to zero against equal trailing averages; the earlier
        // series (Network traffic) wins the tie.
        let day: [MetricKind: Int64] = [.networkBytesIn: mb(400), .diskBytesRead: mb(400)]
        let trailing = Array(repeating: day, count: 3)
        let note = MarginNotes.note(today: [:], trailing: trailing)
        XCTAssertEqual(note.rule, .variance)
        XCTAssertEqual(note.text, "Network traffic down 100% versus the trailing average. No judgment. Filing it.")
    }

    func testVarianceIgnoredBelowThreshold() {
        // A 50% swing is under the 100% threshold, so a lower-priority rule speaks instead.
        let trailing = Array(repeating: [MetricKind.networkBytesIn: mb(100)], count: 3)
        let today: [MetricKind: Int64] = [.networkBytesIn: mb(150)]
        let note = MarginNotes.note(today: today, trailing: trailing)
        XCTAssertNotEqual(note.rule, .variance)
    }

    func testGeneratedExceedsTypedRule() {
        // No trailing days, so variance cannot fire; generated tokens outnumber keystrokes.
        let today: [MetricKind: Int64] = [.aiOutputTokens: 12_300, .inputKeystrokes: 8_412]
        let note = MarginNotes.note(today: today, trailing: [])
        XCTAssertEqual(note.rule, .generatedExceedsTyped)
        XCTAssertEqual(note.text, "Tokens receivable outran keys struck, 12,300 to 8,412. Booking the surplus to the machine.")
    }

    func testLargestAccountRulePicksStorage() {
        let today: [MetricKind: Int64] = [
            .networkBytesIn: mb(50),
            .diskBytesWritten: mb(300),
            .diskBytesRead: mb(300),
        ]
        let note = MarginNotes.note(today: today, trailing: [])
        XCTAssertEqual(note.rule, .largestAccount)
        XCTAssertEqual(note.text, "Storage Account carried the day at 600.0 MB posted. Entered without comment.")
    }

    func testLargestAccountTieBreaksToTraffic() {
        // Equal byte churn resolves to the Traffic Account by fixed order.
        let today: [MetricKind: Int64] = [.networkBytesIn: mb(300), .diskBytesRead: mb(300)]
        let note = MarginNotes.note(today: today, trailing: [])
        XCTAssertEqual(note.rule, .largestAccount)
        XCTAssertEqual(note.text, "Traffic Account carried the day at 300.0 MB posted. Entered without comment.")
    }

    func testQuietDayRule() {
        let today: [MetricKind: Int64] = [.networkBytesIn: 1_000, .aiInputTokens: 10, .inputKeystrokes: 5]
        let note = MarginNotes.note(today: today, trailing: [])
        XCTAssertEqual(note.rule, .quietDay)
        XCTAssertEqual(note.text, "Quiet books. Little posted today. The ledger keeps its own counsel.")
    }

    func testFallbackRule() {
        // Active enough not to be quiet (keys past the floor), but no byte account is large and no
        // other rule qualifies.
        let today: [MetricKind: Int64] = [.inputKeystrokes: 1_000, .networkBytesIn: mb(1)]
        let note = MarginNotes.note(today: today, trailing: [])
        XCTAssertEqual(note.rule, .fallback)
        XCTAssertEqual(note.text, "Books balanced against the day. Nothing stands out. Filed as usual.")
    }

    private func indexed(_ index: Int) -> Composite {
        .indexed(CompositeReading(index: index, ratios: [], dropped: []))
    }

    func testCompositeRuleFiresHighAndOutranksVariance() {
        // The trailing data would fire the variance rule; the exceptional Composite speaks first.
        let trailing = Array(repeating: [MetricKind.networkBytesIn: mb(100)], count: 3)
        let today: [MetricKind: Int64] = [.networkBytesIn: mb(500)]
        let note = MarginNotes.note(today: today, trailing: trailing, composite: indexed(214))
        XCTAssertEqual(note.rule, .composite)
        XCTAssertEqual(note.text, "Composite at 214 versus the 28-day median. The whole book ran heavy. Filing it.")
    }

    func testCompositeRuleFiresLow() {
        let note = MarginNotes.note(today: [:], trailing: [], composite: indexed(42))
        XCTAssertEqual(note.rule, .composite)
        XCTAssertEqual(note.text, "Composite at 42 versus the 28-day median. The whole book ran light. Filing it.")
    }

    func testCompositeRuleSilentInsideTheBand() {
        // 199 and 51 sit strictly inside the factor-of-two band, so lower-priority rules speak.
        for index in [199, 132, 100, 51] {
            let note = MarginNotes.note(today: [:], trailing: [], composite: indexed(index))
            XCTAssertNotEqual(note.rule, .composite, "index \(index) must not fire the composite rule")
        }
    }

    func testCompositeRuleIgnoresNonIndexedStates() {
        for composite in [Composite.collecting(recordedDays: 2), .noBaseline] {
            let note = MarginNotes.note(today: [:], trailing: [], composite: composite)
            XCTAssertNotEqual(note.rule, .composite)
        }
        // And a nil composite keeps the pre-iteration-10 order exactly.
        XCTAssertEqual(MarginNotes.note(today: [:], trailing: []).rule, .quietDay)
    }

    func testDeterministicAcrossRepeatedCalls() {
        let trailing = Array(repeating: [MetricKind.networkBytesIn: mb(100), .diskBytesRead: mb(80)], count: 5)
        let today: [MetricKind: Int64] = [.networkBytesIn: mb(450), .diskBytesRead: mb(400), .inputKeystrokes: 9_000]
        let first = MarginNotes.note(today: today, trailing: trailing)
        for _ in 0..<10 {
            XCTAssertEqual(MarginNotes.note(today: today, trailing: trailing), first)
        }
    }
}
