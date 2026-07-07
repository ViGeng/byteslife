import XCTest
@testable import ByteLifeCore

/// Drives the attentive/inactive state machine with an injected monotonic clock and idle reader, so
/// accrual, the idle floor, and the sleep-gap behaviour are all deterministic. Notifications and the
/// scheduler are not exercised; `prime()` and `tick()` are called directly.
final class ScreenCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private var timestamp: Date!
    private var dayEpoch: Int64!

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
        timestamp = fixedTimestamp()
        dayEpoch = DayBucket.dayEpoch(for: timestamp)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func total() throws -> Int64 {
        try store.totals(forDayEpoch: dayEpoch)[.screenAttentiveSeconds] ?? 0
    }

    func testAttentiveSecondsAccrueThenStopPastIdleThresholdThenResume() throws {
        var nanos: UInt64 = 0
        var idle: Double = 0
        let collector = ScreenCollector(
            store: store,
            idleThreshold: 300,
            idleSeconds: { idle },
            clock: { nanos },
            now: { self.timestamp }
        )

        collector.prime()                 // active at t=0
        nanos = 60_000_000_000            // +60s
        collector.tick()
        XCTAssertEqual(try total(), 60)

        idle = 400                         // user walked away
        nanos = 120_000_000_000
        collector.tick()                   // interval was still attentive, then re-evaluates to inactive
        XCTAssertEqual(try total(), 120)

        nanos = 180_000_000_000
        collector.tick()                   // whole interval inactive: no gain
        XCTAssertEqual(try total(), 120)

        idle = 0                           // activity resumes
        nanos = 240_000_000_000
        collector.tick()                   // interval was inactive: no gain, then re-evaluates to active
        XCTAssertEqual(try total(), 120)

        nanos = 300_000_000_000
        collector.tick()                   // +60s active again
        XCTAssertEqual(try total(), 180)
    }

    func testSleepGapNotCountedWhenMonotonicClockStops() throws {
        // The injected clock models CLOCK_UPTIME_RAW: it does not advance across a system sleep.
        var nanos: UInt64 = 0
        let collector = ScreenCollector(
            store: store,
            idleThreshold: 300,
            idleSeconds: { 0 },
            clock: { nanos },
            now: { self.timestamp }
        )

        collector.prime()
        nanos = 5_000_000_000  // 5s of attention
        collector.tick()
        XCTAssertEqual(try total(), 5)

        // The machine sleeps; wall time passes but the monotonic clock is frozen. Next tick sees no
        // elapsed monotonic time, so the sleep gap contributes nothing.
        collector.tick()
        XCTAssertEqual(try total(), 5)
    }

    func testSubSecondRemainderCarriesForward() throws {
        var nanos: UInt64 = 0
        let collector = ScreenCollector(
            store: store,
            idleThreshold: 300,
            idleSeconds: { 0 },
            clock: { nanos },
            now: { self.timestamp }
        )

        collector.prime()
        nanos = 1_500_000_000  // 1.5s: emit 1, carry 0.5
        collector.tick()
        XCTAssertEqual(try total(), 1)

        nanos = 3_000_000_000  // +1.5s -> 0.5 carried + 1.5 = 2.0: emit 2 more
        collector.tick()
        XCTAssertEqual(try total(), 3)
    }

    func testStartAndStopAreIdempotent() throws {
        let collector = ScreenCollector(
            store: store,
            tickInterval: .milliseconds(20),
            idleSeconds: { 0 },
            clock: { 0 },
            now: { self.timestamp }
        )
        collector.start()
        collector.start()   // second start is a no-op: no duplicate scheduler or observers
        collector.stop()
        collector.stop()    // second stop is a no-op

        // A full stop leaves the collector restartable.
        collector.start()
        collector.stop()
    }

    func testConcurrentStartStopIsSerialized() throws {
        let collector = ScreenCollector(
            store: store,
            tickInterval: .milliseconds(10),
            idleSeconds: { 0 },
            clock: { 0 },
            now: { self.timestamp }
        )
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            if i % 2 == 0 { collector.start() } else { collector.stop() }
        }
        // Settle to a known state; the transition lock guarantees no scheduler or observer is stranded.
        collector.stop()
        collector.start()
        collector.stop()
    }

    private func sessions() throws -> Int64 {
        try store.totals(forDayEpoch: dayEpoch)[.attentionSessions] ?? 0
    }

    func testAttentionSessionsCountEachRisingEdgeIntoAttentiveness() throws {
        var idle: Double = 0
        var nanos: UInt64 = 0
        let collector = ScreenCollector(
            store: store,
            idleThreshold: 300,
            idleSeconds: { idle },
            clock: { nanos },
            now: { self.timestamp }
        )

        collector.prime()                  // inactive -> attentive: session 1
        XCTAssertEqual(try sessions(), 1)

        idle = 400; nanos = 60_000_000_000
        collector.tick()                   // attentive -> inactive: no new session
        XCTAssertEqual(try sessions(), 1)

        idle = 0; nanos = 120_000_000_000
        collector.tick()                   // inactive -> attentive: session 2
        XCTAssertEqual(try sessions(), 2)

        nanos = 180_000_000_000
        collector.tick()                   // stays attentive: no new session
        XCTAssertEqual(try sessions(), 2)
    }

    func testScreenUnlocksAreCounted() throws {
        let collector = ScreenCollector(
            store: store,
            idleSeconds: { 0 },
            clock: { 0 },
            now: { self.timestamp }
        )
        collector.prime()
        collector.handleUnlock()
        collector.handleUnlock()
        XCTAssertEqual(try store.totals(forDayEpoch: dayEpoch)[.screenUnlocks] ?? 0, 2)
    }
}
