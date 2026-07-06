import XCTest
@testable import ByteLifeCore

/// The event tap itself needs a TCC grant and is not exercised here. These tests cover the
/// drain/accumulate logic (`TapContext`) directly and the permission-gated availability of the
/// collector with an injected preflight, with the tap factored out.
final class InputCollectorTests: XCTestCase {

    func testKeystrokesAccumulateAndDrainResets() {
        let context = TapContext()
        context.addKeystroke()
        context.addKeystroke()
        context.addKeystroke()

        let first = context.drain()
        XCTAssertEqual(first.keystrokes, 3)
        XCTAssertEqual(first.mouseMilliPixels, 0)

        // Draining zeroes the counters.
        XCTAssertEqual(context.drain().keystrokes, 0)
    }

    func testMouseTravelUsesHypotAndConvertsToMilliPixels() {
        let context = TapContext()
        context.addMouse(deltaX: 3, deltaY: 4)  // hypot = 5
        context.addMouse(deltaX: 6, deltaY: 8)  // hypot = 10

        let drained = context.drain()
        XCTAssertEqual(drained.mouseMilliPixels, 15_000) // (5 + 10) px * 1000
        XCTAssertEqual(drained.keystrokes, 0)
    }

    func testConcurrentIncrementsAreAllCountedUnderTheLock() {
        let context = TapContext()
        let iterations = 20_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in context.addKeystroke() }
        XCTAssertEqual(context.drain().keystrokes, Int64(iterations))
    }

    func testAvailabilityReflectsInjectedPreflight() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = InputCollector(store: store, preflight: { false })
        XCTAssertEqual(collector.availability, .needsPermission)
        collector.start()
        XCTAssertEqual(collector.availability, .needsPermission)
        collector.stop()
    }

    func testRequestPermissionOnlyFiresOnExplicitCall() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        var requested = false
        let collector = InputCollector(
            store: store,
            preflight: { false },
            request: { requested = true }
        )
        collector.start()
        XCTAssertFalse(requested, "start() must never raise the permission prompt")

        collector.requestPermission()
        XCTAssertTrue(requested, "only the explicit request path prompts")
        collector.stop()
    }

    func testStartAndStopAreIdempotent() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = InputCollector(
            store: store,
            drainInterval: .milliseconds(20),
            recheckInterval: .milliseconds(20),
            preflight: { false }
        )
        collector.start()
        collector.start()   // second start is a no-op
        XCTAssertEqual(collector.availability, .needsPermission)
        collector.stop()
        collector.stop()    // second stop is a no-op

        // A full stop leaves the collector restartable.
        collector.start()
        XCTAssertEqual(collector.availability, .needsPermission)
        collector.stop()
    }

    func testConcurrentStartStopIsSerialized() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A short recheck interval makes the recheck timer contend for the same transition lock the
        // concurrent start/stop calls take, exercising the serialization under load. preflight is
        // false so no real event tap is created (the tap needs a TCC grant and is untestable here).
        let collector = InputCollector(
            store: store,
            drainInterval: .milliseconds(10),
            recheckInterval: .milliseconds(10),
            preflight: { false }
        )
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if i % 2 == 0 { collector.start() } else { collector.stop() }
        }
        collector.stop()

        // The collector remains usable after the concurrent churn.
        collector.start()
        XCTAssertEqual(collector.availability, .needsPermission)
        collector.stop()
    }
}
