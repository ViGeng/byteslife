import XCTest
@testable import ByteLifeCore

/// Proves the pure edge- and delta-detection rules the sensor deck's counters rest on, so the collectors'
/// transition logic is verified without any hardware.
final class SensorSignalTests: XCTestCase {
    func testRoseCountsOnlyTheFalseToTrueEdge() {
        XCTAssertTrue(SensorSignal.rose(previous: false, current: true))    // the edge
        XCTAssertFalse(SensorSignal.rose(previous: true, current: true))    // already up
        XCTAssertFalse(SensorSignal.rose(previous: true, current: false))   // falling edge
        XCTAssertFalse(SensorSignal.rose(previous: false, current: false))  // still down
        XCTAssertFalse(SensorSignal.rose(previous: nil, current: true))     // first sample only baselines
    }

    func testRiseReturnsPositiveIncreaseOnly() {
        XCTAssertEqual(SensorSignal.rise(previous: 1, current: 3), 2)   // two new connects
        XCTAssertEqual(SensorSignal.rise(previous: 3, current: 2), 0)   // a disconnect is not a connect
        XCTAssertEqual(SensorSignal.rise(previous: 2, current: 2), 0)   // unchanged
        XCTAssertEqual(SensorSignal.rise(previous: nil, current: 4), 0) // baseline never counts
    }

    func testChangedRespectsEpsilonAndBaseline() {
        XCTAssertFalse(SensorSignal.changed(previous: nil, current: 0.5, epsilon: 0.01))   // baseline
        XCTAssertFalse(SensorSignal.changed(previous: 0.50, current: 0.505, epsilon: 0.01)) // within jitter
        XCTAssertTrue(SensorSignal.changed(previous: 0.50, current: 0.52, epsilon: 0.01))   // a real move
        XCTAssertTrue(SensorSignal.changed(previous: 0.52, current: 0.50, epsilon: 0.01))   // moves either way
    }

    func testRebootedOnlyOnAChangedBootTime() {
        XCTAssertFalse(SensorSignal.rebooted(previousBootTime: nil, current: 1000))   // first-ever launch
        XCTAssertFalse(SensorSignal.rebooted(previousBootTime: 1000, current: 1000))  // same boot
        XCTAssertTrue(SensorSignal.rebooted(previousBootTime: 1000, current: 2000))   // rebooted since
    }
}
