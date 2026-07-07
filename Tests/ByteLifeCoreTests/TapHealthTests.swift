import XCTest
@testable import ByteLifeCore

/// The stale-tap detector is a pure state machine with no clock of its own, so these tests drive it with
/// hand-fed observations: each carries the input events and attentive seconds accrued since the previous
/// observation. Attentive time is fed in 60-second chunks so "three attentive minutes" reads literally.
final class TapHealthTests: XCTestCase {

    func testHealthyTypingNeverFlags() {
        var health = TapHealth()
        // Every interval carries real input, so the tap is plainly delivering. Even across a long stretch
        // of attentive minutes the run never accumulates.
        for _ in 0..<10 {
            XCTAssertFalse(health.observe(inputEvents: 40, attentiveSeconds: 60))
        }
        XCTAssertEqual(health.zeroInputAttentiveSeconds, 0)
        XCTAssertFalse(health.isSuspect)
    }

    func testAttentiveWithZeroInputFlagsAfterThreeMinutes() {
        var health = TapHealth()
        // Two attentive minutes with not one event is not yet enough: the threshold is conservative.
        XCTAssertFalse(health.observe(inputEvents: 0, attentiveSeconds: 60))
        XCTAssertFalse(health.observe(inputEvents: 0, attentiveSeconds: 60))
        XCTAssertEqual(health.zeroInputAttentiveSeconds, 120)
        // The third attentive minute reaches 180s and trips the flag.
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 60))
        XCTAssertTrue(health.isSuspect)
    }

    func testGenuineIdleNeverFlags() {
        var health = TapHealth()
        // The user stepped away: no input and no attentive time. The run must not grow, however long the
        // machine sits idle, so a screen left on overnight never forges a stale-tap flag.
        for _ in 0..<100 {
            XCTAssertFalse(health.observe(inputEvents: 0, attentiveSeconds: 0))
        }
        XCTAssertEqual(health.zeroInputAttentiveSeconds, 0)
        XCTAssertFalse(health.isSuspect)
    }

    func testRecoveryClearsFlagAndRunWhenInputResumes() {
        var health = TapHealth()
        // Drive it to suspect.
        health.observe(inputEvents: 0, attentiveSeconds: 120)
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 120))
        XCTAssertTrue(health.isSuspect)

        // Events flow again: the tap is delivering, so the flag clears and the run resets at once.
        XCTAssertFalse(health.observe(inputEvents: 1, attentiveSeconds: 60))
        XCTAssertFalse(health.isSuspect)
        XCTAssertEqual(health.zeroInputAttentiveSeconds, 0)
    }

    func testFlagLatchesUntilInputResumes() {
        var health = TapHealth()
        health.observe(inputEvents: 0, attentiveSeconds: 120)
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 120))
        // Further attentive-but-silent intervals keep it suspect.
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 60))
        // A stretch of genuine idle also leaves the latch untouched: recovery needs real input.
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 0))
        XCTAssertTrue(health.isSuspect)
    }

    func testInputMidRunRestartsTheAccumulation() {
        var health = TapHealth()
        health.observe(inputEvents: 0, attentiveSeconds: 120)  // run 120
        health.observe(inputEvents: 5, attentiveSeconds: 60)   // input resets run to 0
        XCTAssertEqual(health.zeroInputAttentiveSeconds, 0)
        // A fresh full run is required to flag again; two minutes is still short.
        XCTAssertFalse(health.observe(inputEvents: 0, attentiveSeconds: 120))
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 60))
    }

    func testThresholdIsTunable() {
        var health = TapHealth(suspectAfterAttentiveSeconds: 120)
        XCTAssertFalse(health.observe(inputEvents: 0, attentiveSeconds: 60))
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 60))
    }

    func testResetClearsRunAndFlag() {
        var health = TapHealth()
        health.observe(inputEvents: 0, attentiveSeconds: 120)
        XCTAssertTrue(health.observe(inputEvents: 0, attentiveSeconds: 120))
        health.reset()
        XCTAssertFalse(health.isSuspect)
        XCTAssertEqual(health.zeroInputAttentiveSeconds, 0)
    }
}
