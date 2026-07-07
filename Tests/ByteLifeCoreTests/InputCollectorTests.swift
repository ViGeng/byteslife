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

    func testClicksAndScrollsAccumulateAndDrainResets() {
        let context = TapContext()
        context.addClick()
        context.addClick()
        context.addScroll(units: 12)
        context.addScroll(units: 8)
        // A non-positive scroll event contributes nothing.
        context.addScroll(units: 0)

        let first = context.drain()
        XCTAssertEqual(first.clicks, 2)
        XCTAssertEqual(first.scrollUnits, 20)
        // The other counters stay independent.
        XCTAssertEqual(first.keystrokes, 0)
        XCTAssertEqual(first.mouseMilliPixels, 0)

        // Draining zeroes the new counters too.
        let second = context.drain()
        XCTAssertEqual(second.clicks, 0)
        XCTAssertEqual(second.scrollUnits, 0)
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

    func testRequestPermissionReportsGrantedWhenGrantAppears() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The request "grants": preflight flips true, mirroring the user allowing the prompt.
        var granted = false
        let collector = InputCollector(
            store: store,
            preflight: { granted },
            request: { granted = true }
        )
        XCTAssertEqual(collector.requestPermission(), .granted)
    }

    func testRequestPermissionReportsPromptSuppressedWhenGrantStaysAbsent() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The request returns but preflight stays false: macOS suppressed the repeat prompt.
        let collector = InputCollector(store: store, preflight: { false }, request: {})
        XCTAssertEqual(collector.requestPermission(), .promptSuppressed)
    }

    func testResetPermissionStateRepromptsOnSuccessAndReRaisesPromptOnce() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        var requests = 0
        let collector = InputCollector(
            store: store,
            preflight: { false },
            request: { requests += 1 },
            resetTCC: { 0 }
        )
        XCTAssertEqual(collector.resetPermissionState(), .reprompted)
        XCTAssertEqual(requests, 1, "a successful reset re-raises the prompt exactly once")
    }

    func testResetPermissionStateReportsFailureExitCodeAndNeverReprompts() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        var requests = 0
        let collector = InputCollector(
            store: store,
            preflight: { false },
            request: { requests += 1 },
            resetTCC: { 42 }
        )
        XCTAssertEqual(collector.resetPermissionState(), .failed(exitCode: 42))
        XCTAssertEqual(requests, 0, "a failed reset must not re-raise the prompt")
    }

    func testTCCResetArgumentsTargetListenEventForTheBundle() {
        XCTAssertEqual(
            TCCReset.arguments(bundleID: "com.vigeng.bytelife"),
            ["reset", "ListenEvent", "com.vigeng.bytelife"]
        )
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

    func testTapSuspectStaleIsFalseByDefault() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        let collector = InputCollector(store: store, preflight: { false })
        XCTAssertFalse(collector.tapSuspectStale)
    }

    /// The stale-tap end-to-end path: the grant is present and the tap reports running (both injected,
    /// since a real `CGEventTap` cannot reach the silent state without a TCC grant), but the injected
    /// totals show attentive time climbing with zero input. The detector must flag the tap, drop the
    /// collector to needs-permission, and raise the re-grant suspicion; once input resumes it recovers.
    func testStaleTapFlagsRegrantThenRecoversWhenInputResumes() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A thread-safe cumulative-totals source read once per recheck. Attentive climbs 60s each
        // interval; input stays flat until `inputFlowing` flips, simulating a running-but-silent tap
        // and then a recovered one.
        let lock = NSLock()
        var attentive: Int64 = 0
        var input: Int64 = 0
        var inputFlowing = false
        let provider: () -> (inputEvents: Int64, attentiveSeconds: Int64) = {
            lock.lock(); defer { lock.unlock() }
            attentive += 60
            if inputFlowing { input += 100 }
            return (input, attentive)
        }

        let collector = InputCollector(
            store: store,
            drainInterval: .milliseconds(50),
            recheckInterval: .milliseconds(10),
            preflight: { true },
            healthTotalsProvider: provider,
            tapStarter: { true }
        )
        collector.start()
        // The tap looks live and delivering on the first frame.
        XCTAssertEqual(collector.availability, .running)

        // Three attentive minutes of zero input trip the flag within a handful of 10ms rechecks.
        let flagged = expectation(description: "stale tap flagged")
        pollUntil(flagged) {
            collector.tapSuspectStale && collector.availability == .needsPermission
        }
        wait(for: [flagged], timeout: 3)

        // Events resume: the flag clears and availability returns to running.
        lock.lock(); inputFlowing = true; lock.unlock()
        let recovered = expectation(description: "recovered")
        pollUntil(recovered) {
            !collector.tapSuspectStale && collector.availability == .running
        }
        wait(for: [recovered], timeout: 3)

        collector.stop()
    }

    /// The mouse-only-use guard: against the real store and the DEFAULT health-totals provider, attentive
    /// seconds and mouse travel climb together while keys, clicks, and scrolls never move. Because those
    /// three never move, the only signal that can keep the tap trusted is folded-in mouse travel; if the
    /// provider ignored it the detector would latch suspect after three attentive minutes and, with no
    /// keys/clicks/scrolls ever resuming, never recover. So a false flag here would still read suspect at
    /// the end, which makes the final assertion a reliable discriminator.
    func testMouseOnlyAttentiveUseNeverFlagsWithDefaultProvider() throws {
        let (store, directory) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let collector = InputCollector(
            store: store,
            drainInterval: .milliseconds(50),
            recheckInterval: .milliseconds(10),
            preflight: { true },
            tapStarter: { true }
        )
        collector.start()
        defer { collector.stop() }

        // Each step books a minute of attention and some mouse travel in one transaction, so any recheck
        // reads a consistent snapshot. Spread across the collector's rechecks, this climbs far past the
        // 180s zero-input threshold while keys, clicks, and scrolls stay flat.
        let climbed = expectation(description: "attentive climbed past threshold")
        var steps = 0
        func drive() {
            try? store.record([
                Sample(kind: .screenAttentiveSeconds, value: 60, timestamp: now),
                Sample(kind: .inputMouseMilliPixels, value: 5_000, timestamp: now),
            ])
            steps += 1
            if steps >= 20 { climbed.fulfill(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(15)) { drive() }
        }
        drive()
        wait(for: [climbed], timeout: 5)

        XCTAssertFalse(collector.tapSuspectStale, "a live mouse must keep the tap trusted")
        XCTAssertEqual(collector.availability, .running)
    }

    /// Polls `condition` off the main thread every 10ms, fulfilling `expectation` once it holds. The
    /// collector's availability and suspect flag are lock-guarded, so a cross-thread poll reads them
    /// safely.
    private func pollUntil(_ expectation: XCTestExpectation, _ condition: @escaping () -> Bool) {
        func check() {
            if condition() { expectation.fulfill(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(10)) { check() }
        }
        check()
    }
}
