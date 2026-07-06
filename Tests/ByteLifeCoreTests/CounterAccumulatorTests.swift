import XCTest
@testable import ByteLifeCore

final class CounterAccumulatorTests: XCTestCase {

    func testNilPreviousBaselinesSilently() {
        XCTAssertEqual(CounterAccumulator.delta(previous: nil, current: 1_000), 0)
    }

    func testIncreaseEmitsDifference() {
        XCTAssertEqual(CounterAccumulator.delta(previous: 1_000, current: 1_500), 500)
    }

    func testEqualEmitsZero() {
        XCTAssertEqual(CounterAccumulator.delta(previous: 1_000, current: 1_000), 0)
    }

    func testDecreaseTreatedAsResetEmitsZero() {
        // A reboot or device re-enumeration drops the counter; never emit a wrapped huge value.
        XCTAssertEqual(CounterAccumulator.delta(previous: 5_000, current: 10), 0)
    }

    func testLargeDeltaWithinInt64Range() {
        XCTAssertEqual(CounterAccumulator.delta(previous: 0, current: 9_000_000_000), 9_000_000_000)
    }

    func testHugeDeltaClampsToInt64Max() {
        XCTAssertEqual(CounterAccumulator.delta(previous: 0, current: UInt64.max), Int64.max)
    }
}
