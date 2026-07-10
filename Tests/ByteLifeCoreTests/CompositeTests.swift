import XCTest
@testable import ByteLifeCore

final class CompositeTests: XCTestCase {
    /// Start-of-day epoch seconds for day number `n`.
    private func day(_ n: Int) -> Int64 { Int64(n) * 86_400 }

    /// A history map with one metric kind, one value per consecutive day starting at `startDay`.
    private func history(
        _ values: [Int64], kind: MetricKind = .screenAttentiveSeconds, startDay: Int = 0
    ) -> [Int64: [MetricKind: Int64]] {
        var map: [Int64: [MetricKind: Int64]] = [:]
        for (i, value) in values.enumerated() { map[day(startDay + i)] = [kind: value] }
        return map
    }

    private func reading(_ state: Composite, file: StaticString = #filePath,
                         line: UInt = #line) -> CompositeReading? {
        guard case .indexed(let reading) = state else {
            XCTFail("expected .indexed, got \(state)", file: file, line: line)
            return nil
        }
        return reading
    }

    private func ratio(_ state: Composite, _ component: CompositeComponent,
                       file: StaticString = #filePath, line: UInt = #line) -> CompositeRatio? {
        guard let reading = reading(state, file: file, line: line) else { return nil }
        guard let ratio = reading.ratios.first(where: { $0.component == component }) else {
            XCTFail("no ratio for \(component)", file: file, line: line)
            return nil
        }
        return ratio
    }

    // MARK: Median baseline

    /// An odd baseline count takes the middle value, unmoved by an outlier day.
    func testMedianBaselineOddCount() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 300],
            history: history([100, 900_000, 300, 200, 250])
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.baseline, 250)
        XCTAssertEqual(r.ratio, 1.2, accuracy: 1e-9)
    }

    /// An even baseline count takes the mean of the two middle values (here 3.5 from 3 and 4).
    func testMedianBaselineEvenCount() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 7],
            history: history([1, 2, 3, 4, 5, 6])
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.baseline, 3.5)
        XCTAssertEqual(r.ratio, 2.0, accuracy: 1e-9)
    }

    /// Recorded days with calendar gaps between them still count as baseline days.
    func testCalendarGapsDoNotBreakTheBaseline() {
        var map: [Int64: [MetricKind: Int64]] = [:]
        for n in [1, 4, 9, 20, 40] { map[day(n)] = [.screenAttentiveSeconds: 100] }
        let state = Composite.build(
            dayEpoch: day(50), todayTotals: [.screenAttentiveSeconds: 100], history: map
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.baseline, 100)
    }

    /// The direct median helper: odd takes the middle, even averages the middles.
    func testMedianHelper() {
        XCTAssertEqual(Composite.median([5, 1, 3]), 3)
        XCTAssertEqual(Composite.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(Composite.median([7]), 7)
    }

    // MARK: Geometric mean

    /// The index is the geometric mean of the ratios times 100: ratios 4 and 1 read 200, not the
    /// arithmetic 250.
    func testIndexIsGeometricMeanTimes100() {
        var map: [Int64: [MetricKind: Int64]] = [:]
        for n in 0..<5 { map[day(n)] = [.screenAttentiveSeconds: 100, .inputKeystrokes: 100] }
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 400, .inputKeystrokes: 100],
            history: map
        )
        guard let r = reading(state) else { return }
        XCTAssertEqual(r.index, 200)
        XCTAssertEqual(r.dropped, [.bytesMoved, .tokens])
    }

    /// A typical day, every component at its own median, reads exactly 100.
    func testTypicalDayReads100() {
        var map: [Int64: [MetricKind: Int64]] = [:]
        for n in 0..<7 {
            map[day(n)] = [.networkBytesIn: 1_000, .aiInputTokens: 50,
                           .screenAttentiveSeconds: 3_600, .inputKeystrokes: 500]
        }
        let state = Composite.build(
            dayEpoch: day(7),
            todayTotals: [.networkBytesIn: 1_000, .aiInputTokens: 50,
                          .screenAttentiveSeconds: 3_600, .inputKeystrokes: 500],
            history: map
        )
        guard let r = reading(state) else { return }
        XCTAssertEqual(r.index, 100)
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertEqual(r.ratios.map(\.component), CompositeComponent.allCases)
    }

    // MARK: Clamping

    /// A zero day against a live baseline clamps to the 0.05 floor instead of reading 0.
    func testRatioClampsAtFloor() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [:],
            history: history([100, 100, 100, 100, 100])
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.today, 0)
        XCTAssertEqual(r.ratio, 0.05)
        XCTAssertEqual(reading(state)?.index, 5)
    }

    /// A wild day clamps to the 20x ceiling so it cannot dominate the index.
    func testRatioClampsAtCeiling() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 1_000_000],
            history: history([100, 100, 100, 100, 100])
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.ratio, 20.0)
        XCTAssertEqual(reading(state)?.index, 2_000)
    }

    // MARK: Zero-baseline dropout

    /// A component with a zero baseline but activity today drops out with disclosure instead of
    /// fabricating a clamped ratio, and the index computes from the remaining components.
    func testZeroBaselineNonzeroTodayDropsWithDisclosure() {
        // The attention baseline is 100; tokens were never recorded, yet burn today.
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 132, .aiInputTokens: 9_999],
            history: history([100, 100, 100, 100, 100])
        )
        guard let r = reading(state) else { return }
        XCTAssertEqual(r.dropped, [.bytesMoved, .tokens, .inputEvents])
        XCTAssertEqual(r.ratios.map(\.component), [.attention])
        XCTAssertEqual(r.index, 132)
        XCTAssertEqual(state.disclosure, "bytes, tokens, input excluded (zero baseline)")
    }

    /// Zero baseline and zero today drops the same way: no denominator, no ratio, disclosed.
    func testZeroBaselineZeroTodayDrops() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 100],
            history: history([100, 100, 100, 100, 100])
        )
        guard let r = reading(state) else { return }
        XCTAssertTrue(r.dropped.contains(.tokens))
        XCTAssertEqual(r.index, 100)
    }

    /// When every component's baseline is zero the state is `noBaseline`, distinct from `collecting`,
    /// with an honest dash and disclosure.
    func testAllComponentsDroppedReadsNoBaseline() {
        var map: [Int64: [MetricKind: Int64]] = [:]
        for n in 0..<6 { map[day(n)] = [:] }
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 500],
            history: map
        )
        XCTAssertEqual(state, .noBaseline)
        XCTAssertEqual(state.chipValue, "—")
        XCTAssertEqual(state.receiptLine, "Composite vs 28-day median: no baseline")
        XCTAssertEqual(state.disclosure, "all components excluded (zero baseline)")
    }

    // MARK: Insufficient history

    /// Fewer than 5 recorded baseline days reads `collecting`, never a number.
    func testInsufficientHistoryCollects() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 100],
            history: history([100, 100, 100, 100])
        )
        XCTAssertEqual(state, .collecting(recordedDays: 4))
        XCTAssertEqual(state.chipValue, "—")
        XCTAssertEqual(state.receiptLine, "Composite vs 28-day median: collecting baseline (4 of 5 days)")
        XCTAssertNil(state.disclosure)
    }

    /// An empty history collects from zero.
    func testEmptyHistoryCollectsFromZero() {
        let state = Composite.build(dayEpoch: day(0), todayTotals: [:], history: [:])
        XCTAssertEqual(state, .collecting(recordedDays: 0))
    }

    /// Exactly 5 recorded baseline days is enough to index.
    func testFiveRecordedDaysIndexes() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 100],
            history: history([100, 100, 100, 100, 100])
        )
        XCTAssertNotNil(reading(state))
    }

    // MARK: Window bounds

    /// Days at or after the target day never enter the baseline, even when present in the map: with only
    /// 4 recorded days strictly before, the state stays `collecting` despite later recorded days.
    func testDaysAtOrAfterTargetAreExcluded() {
        var map = history([100, 100, 100, 100])
        map[day(10)] = [.screenAttentiveSeconds: 900_000] // the target day itself
        map[day(11)] = [.screenAttentiveSeconds: 900_000] // a later day
        let state = Composite.build(
            dayEpoch: day(10), todayTotals: [.screenAttentiveSeconds: 100], history: map
        )
        XCTAssertEqual(state, .collecting(recordedDays: 4))
    }

    /// With enough prior days, at-or-after days still leave the median untouched.
    func testAtOrAfterDaysDoNotMoveTheMedian() {
        var map = history([100, 100, 100, 100, 100])
        map[day(10)] = [.screenAttentiveSeconds: 900_000]
        map[day(12)] = [.screenAttentiveSeconds: 900_000]
        let state = Composite.build(
            dayEpoch: day(10), todayTotals: [.screenAttentiveSeconds: 200], history: map
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.baseline, 100)
    }

    /// Only the trailing 28 recorded days count: a 29th, older day with a wild value cannot move the
    /// median.
    func testBaselineWindowCapsAt28RecordedDays() {
        var map = history(Array(repeating: Int64(100), count: 28), startDay: 1)
        map[day(0)] = [.screenAttentiveSeconds: 900_000] // 29th recorded day, outside the window
        let state = Composite.build(
            dayEpoch: day(29), todayTotals: [.screenAttentiveSeconds: 100], history: map
        )
        guard let r = ratio(state, .attention) else { return }
        XCTAssertEqual(r.baseline, 100)
    }

    // MARK: Component composition

    /// Bytes moved sums network in+out plus disk read+written; tokens sums input plus output with cache
    /// excluded; input events sums keystrokes, clicks, and scroll units.
    func testComponentComposition() {
        let totals: [MetricKind: Int64] = [
            .networkBytesIn: 1, .networkBytesOut: 2, .diskBytesRead: 4, .diskBytesWritten: 8,
            .aiInputTokens: 10, .aiOutputTokens: 20,
            .aiCacheCreationTokens: 999_999, .aiCacheReadTokens: 999_999,
            .screenAttentiveSeconds: 60,
            .inputKeystrokes: 100, .inputClicks: 200, .inputScrollUnits: 400,
            .inputMouseMilliPixels: 999_999,
        ]
        XCTAssertEqual(CompositeComponent.bytesMoved.value(in: totals), 15)
        XCTAssertEqual(CompositeComponent.tokens.value(in: totals), 30)
        XCTAssertEqual(CompositeComponent.attention.value(in: totals), 60)
        XCTAssertEqual(CompositeComponent.inputEvents.value(in: totals), 700)
    }

    // MARK: Display strings

    /// The indexed state prints the chip figure and the receipt fragment from the same rounded index.
    func testIndexedDisplayStrings() {
        let state = Composite.build(
            dayEpoch: day(10),
            todayTotals: [.screenAttentiveSeconds: 132],
            history: history([100, 100, 100, 100, 100])
        )
        XCTAssertEqual(state.chipValue, "132")
        XCTAssertEqual(state.receiptLine, "Composite vs 28-day median: 132")
        XCTAssertEqual(Composite.chipLabel, "COMPOSITE")
    }
}
