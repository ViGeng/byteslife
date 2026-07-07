import XCTest
@testable import ByteLifeCore

/// The typing-cadence derivation is pure, so these pin the peak, the average over active minutes, and
/// the empty-day behaviour directly.
final class TypingCadenceTests: XCTestCase {
    func testPeakAndAverageOverActiveMinutes() {
        // Minutes with keystrokes: 5, 10, 3 (three active). Idle minutes are ignored for the average.
        let cadence = TypingCadence.from(minuteKeystrokes: [0, 5, 0, 10, 3, 0])
        XCTAssertEqual(cadence.peakKeysPerMinute, 10)
        XCTAssertEqual(cadence.activeMinutes, 3)
        XCTAssertEqual(cadence.averageKeysPerActiveMinute, 18.0 / 3.0, accuracy: 1e-9)
    }

    func testSingleActiveMinute() {
        let cadence = TypingCadence.from(minuteKeystrokes: [0, 0, 42, 0])
        XCTAssertEqual(cadence.peakKeysPerMinute, 42)
        XCTAssertEqual(cadence.activeMinutes, 1)
        XCTAssertEqual(cadence.averageKeysPerActiveMinute, 42, accuracy: 1e-9)
    }

    func testEmptyAndAllZeroDaysReadAsZero() {
        for buckets in [[], [Int64](repeating: 0, count: 100)] {
            let cadence = TypingCadence.from(minuteKeystrokes: buckets)
            XCTAssertEqual(cadence.peakKeysPerMinute, 0)
            XCTAssertEqual(cadence.averageKeysPerActiveMinute, 0)
            XCTAssertEqual(cadence.activeMinutes, 0)
        }
    }
}
