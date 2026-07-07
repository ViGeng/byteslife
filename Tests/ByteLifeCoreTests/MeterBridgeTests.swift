import XCTest
@testable import ByteLifeCore

final class MeterBridgeTests: XCTestCase {
    private let running: [MetricFamily: Availability] = [
        .ai: .running, .network: .running, .disk: .running, .screen: .running, .input: .running,
    ]
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snap(_ totals: [MetricKind: Int64], at date: Date) -> MeterSnapshot {
        MeterSnapshot(totals: totals, timestamp: date)
    }

    private func channel(_ bridge: MeterBridge, _ kind: MeterChannelKind) -> MeterChannel {
        bridge.channels.first { $0.kind == kind }!
    }

    private func build(
        current: MeterSnapshot,
        previous: MeterSnapshot? = nil,
        series: [MetricKind: [Int64]] = [:],
        availability: [MetricFamily: Availability]? = nil,
        priorState: MeterState = .initial
    ) -> MeterBridge {
        MeterBridge.build(
            current: current,
            previous: previous,
            series: series,
            availabilityByFamily: availability ?? running,
            priorState: priorState
        )
    }

    // MARK: - Shape

    func testChannelsAreTheFiveInConceptOrder() {
        let bridge = build(current: snap([:], at: t0))
        XCTAssertEqual(bridge.channels.map(\.kind),
                       [.traffic, .storage, .cognition, .exposure, .mechanics])
        XCTAssertEqual(MeterChannelKind.allCases,
                       [.traffic, .storage, .cognition, .exposure, .mechanics])
        XCTAssertEqual(channel(bridge, .cognition).title, "COGNITION")
    }

    func testTrackedKindsExcludeCacheTokens() {
        XCTAssertTrue(MeterBridge.trackedKinds.contains(.aiInputTokens))
        XCTAssertTrue(MeterBridge.trackedKinds.contains(.aiOutputTokens))
        XCTAssertFalse(MeterBridge.trackedKinds.contains(.aiCacheCreationTokens))
        XCTAssertFalse(MeterBridge.trackedKinds.contains(.aiCacheReadTokens))
    }

    // MARK: - Rate from two snapshots

    func testTrafficRateFromDeltaOverElapsed() {
        // 6000 bytes over 2 seconds is 3000 B/s raw; a first EMA step from 0 halves it.
        let bridge = build(
            current: snap([.networkBytesIn: 7_000], at: t0.addingTimeInterval(2)),
            previous: snap([.networkBytesIn: 1_000], at: t0)
        )
        let traffic = channel(bridge, .traffic)
        XCTAssertEqual(traffic.rate, 1_500, accuracy: 0.001)
        XCTAssertEqual(traffic.rateReadout, "1.5 KB/s")
        XCTAssertEqual(traffic.peak, 1_500, accuracy: 0.001)
    }

    func testCognitionRateIsTokensPerMinuteExcludingCache() {
        // 600 input + 400 output = 1000 real tokens over 2 seconds -> 30000 tok/min raw. Cache tokens
        // are present but must not enter the rate. First EMA step from 0 halves it to 15000.
        let previous = snap(
            [.aiInputTokens: 0, .aiOutputTokens: 0, .aiCacheReadTokens: 0], at: t0)
        let current = snap(
            [.aiInputTokens: 600, .aiOutputTokens: 400, .aiCacheReadTokens: 9_000_000],
            at: t0.addingTimeInterval(2))
        let cognition = channel(build(current: current, previous: previous), .cognition)
        XCTAssertEqual(cognition.rate, 15_000, accuracy: 0.001)
    }

    func testFirstPollHasNoRateOrPeak() {
        let bridge = build(current: snap([.networkBytesIn: 5_000], at: t0), previous: nil)
        let traffic = channel(bridge, .traffic)
        XCTAssertEqual(traffic.rate, 0)
        XCTAssertEqual(traffic.rateReadout, "0 B/s")
        XCTAssertNil(traffic.peakPosition)
    }

    func testZeroElapsedHoldsPriorSmoothedRate() {
        // Same timestamp on both snapshots: the guard holds the carried value rather than dividing by 0.
        let prior = MeterState(smoothedRate: [.traffic: 1_500], peakRate: [.traffic: 1_500])
        let bridge = build(
            current: snap([.networkBytesIn: 99_999], at: t0),
            previous: snap([.networkBytesIn: 1_000], at: t0),
            priorState: prior
        )
        XCTAssertEqual(channel(bridge, .traffic).rate, 1_500, accuracy: 0.001)
    }

    func testCounterNoiseNegativeDeltaClampsToZeroAndPeakIsRetained() {
        // The counter appears to slip backward by 10 (noise / midnight reset): raw rate must clamp to 0,
        // so the EMA decays toward 0, while peak-hold keeps the prior high.
        let prior = MeterState(smoothedRate: [.traffic: 1_500], peakRate: [.traffic: 1_500])
        let bridge = build(
            current: snap([.networkBytesIn: 6_990], at: t0.addingTimeInterval(2)),
            previous: snap([.networkBytesIn: 7_000], at: t0),
            priorState: prior
        )
        let traffic = channel(bridge, .traffic)
        XCTAssertEqual(traffic.rate, 750, accuracy: 0.001)
        XCTAssertEqual(traffic.peak, 1_500, accuracy: 0.001)
    }

    // MARK: - EMA smoothing

    func testEMAConvergesTowardRawAcrossPolls() {
        let prior = MeterState(smoothedRate: [.traffic: 1_000])
        let step1 = build(
            current: snap([.networkBytesIn: 7_000], at: t0.addingTimeInterval(2)),
            previous: snap([.networkBytesIn: 1_000], at: t0),
            priorState: prior
        )
        // 0.5 * 3000 + 0.5 * 1000 = 2000.
        XCTAssertEqual(channel(step1, .traffic).rate, 2_000, accuracy: 0.001)

        // Threading the state forward and applying the same 3000 raw again climbs toward 3000.
        let step2 = build(
            current: snap([.networkBytesIn: 13_000], at: t0.addingTimeInterval(4)),
            previous: snap([.networkBytesIn: 7_000], at: t0.addingTimeInterval(2)),
            priorState: step1.state
        )
        // 0.5 * 3000 + 0.5 * 2000 = 2500.
        XCTAssertEqual(channel(step2, .traffic).rate, 2_500, accuracy: 0.001)
        XCTAssertGreaterThan(channel(step2, .traffic).rate, channel(step1, .traffic).rate)
    }

    // MARK: - Normalization with floor

    func testIdleWindowStaysFlatAgainstTheFloor() {
        // Each minute holds 6000 bytes -> 100 B/s, far below the 64 KB/s floor, so no bar approaches full.
        let series: [MetricKind: [Int64]] = [.networkBytesIn: [6_000, 6_000, 6_000]]
        let traffic = channel(build(current: snap([:], at: t0), series: series), .traffic)
        XCTAssertEqual(traffic.bars.count, 3)
        XCTAssertLessThan(traffic.bars.max()!, 0.01)
    }

    func testSingleSpikeWindowPinsOnlyTheSpikeToFull() {
        // One 6,553,600-byte minute -> ~109 KB/s, above the floor and the sole window maximum.
        let series: [MetricKind: [Int64]] = [.networkBytesIn: [0, 6_553_600, 0]]
        let bars = channel(build(current: snap([:], at: t0), series: series), .traffic).bars
        XCTAssertEqual(bars[0], 0, accuracy: 0.0001)
        XCTAssertEqual(bars[1], 1.0, accuracy: 0.0001)
        XCTAssertEqual(bars[2], 0, accuracy: 0.0001)
    }

    func testCognitionBarsUsePerMinuteBucketsDirectly() {
        // Token buckets are already per-minute, so a 300-token minute against a 600-token window max
        // reads exactly half a bar with no per-second division.
        let series: [MetricKind: [Int64]] = [.aiInputTokens: [300, 600], .aiOutputTokens: [0, 0]]
        let bars = channel(build(current: snap([:], at: t0), series: series), .cognition).bars
        XCTAssertEqual(bars[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(bars[1], 1.0, accuracy: 0.0001)
    }

    // MARK: - Peak-hold repositioning

    func testPeakRepositionsWhenTheBarRangeShrinks() {
        let prior = MeterState(peakRate: [.traffic: 3_000])
        // A busy window gives a large range, so the fixed peak sits low on the bar.
        let busy = channel(
            build(current: snap([:], at: t0),
                  series: [.networkBytesIn: [6_553_600]], priorState: prior),
            .traffic
        )
        // An idle window collapses the range to the floor, so the same peak rides higher.
        let idle = channel(
            build(current: snap([:], at: t0),
                  series: [.networkBytesIn: [6_000]], priorState: prior),
            .traffic
        )
        XCTAssertEqual(busy.peak, 3_000, accuracy: 0.001)
        XCTAssertEqual(idle.peak, 3_000, accuracy: 0.001)
        XCTAssertNotNil(busy.peakPosition)
        XCTAssertNotNil(idle.peakPosition)
        XCTAssertGreaterThan(idle.peakPosition!, busy.peakPosition!)
    }

    // MARK: - Peak gap-gating

    func testShortGapRaisesBothRateAndPeak() {
        // A 2-second gap is an honest live poll: 200,000 bytes over 2s = 100,000 B/s raw, a first EMA
        // step from 0 halves it to 50,000, and the session peak rises to meet it.
        let bridge = build(
            current: snap([.networkBytesIn: 200_000], at: t0.addingTimeInterval(2)),
            previous: snap([.networkBytesIn: 0], at: t0)
        )
        let traffic = channel(bridge, .traffic)
        XCTAssertEqual(traffic.rate, 50_000, accuracy: 0.001)
        XCTAssertEqual(traffic.peak, 50_000, accuracy: 0.001)
    }

    func testLongGapRaisesRateButNotPeak() {
        // A 30-second gap is the warm background carry, not a live poll. 3,000,000 bytes over 30s is
        // still 100,000 B/s raw and an honest recent average, so the smoothed rate climbs; but the gap
        // average must never forge a peak, so the prior peak carries through unchanged.
        let prior = MeterState(smoothedRate: [.traffic: 0], peakRate: [.traffic: 1_000])
        let bridge = build(
            current: snap([.networkBytesIn: 3_000_000], at: t0.addingTimeInterval(30)),
            previous: snap([.networkBytesIn: 0], at: t0),
            priorState: prior
        )
        let traffic = channel(bridge, .traffic)
        XCTAssertEqual(traffic.rate, 50_000, accuracy: 0.001)
        XCTAssertEqual(traffic.peak, 1_000, accuracy: 0.001)
    }

    func testLongGapResidueCannotLaunderIntoAPeakThroughTheEMACarry() {
        // The review's laundering scenario: a 30s background carry at 200,000 B/s raw leaves the display
        // EMA at 100,000 (honest recent average, peak gated). The NEXT short tick sees zero bytes; the
        // display EMA halves to 50,000 — but that residue is the long gap's average, and it must not be
        // promoted to a peak by the now-short gap. The peak-only EMA reset on the long gap, so the peak
        // stays where honest short-gap measurements left it.
        let gapStep = build(
            current: snap([.networkBytesIn: 6_000_000], at: t0.addingTimeInterval(30)),
            previous: snap([.networkBytesIn: 0], at: t0),
            priorState: .initial
        )
        XCTAssertEqual(channel(gapStep, .traffic).rate, 100_000, accuracy: 0.001)
        XCTAssertEqual(channel(gapStep, .traffic).peak, 0, accuracy: 0.001)

        let shortStep = build(
            current: snap([.networkBytesIn: 6_000_000], at: t0.addingTimeInterval(32)),
            previous: snap([.networkBytesIn: 6_000_000], at: t0.addingTimeInterval(30)),
            priorState: gapStep.state
        )
        let traffic = channel(shortStep, .traffic)
        XCTAssertEqual(traffic.rate, 50_000, accuracy: 0.001)
        XCTAssertEqual(traffic.peak, 0, accuracy: 0.001)

        // Once real short-gap measurements arrive, the peak-only EMA rebuilds from zero: two 2s ticks at
        // 100,000 B/s raw reach 75,000, and that (not the stale carry) is the recorded peak.
        let live1 = build(
            current: snap([.networkBytesIn: 6_200_000], at: t0.addingTimeInterval(34)),
            previous: snap([.networkBytesIn: 6_000_000], at: t0.addingTimeInterval(32)),
            priorState: shortStep.state
        )
        let live2 = build(
            current: snap([.networkBytesIn: 6_400_000], at: t0.addingTimeInterval(36)),
            previous: snap([.networkBytesIn: 6_200_000], at: t0.addingTimeInterval(34)),
            priorState: live1.state
        )
        XCTAssertEqual(channel(live2, .traffic).peak, 75_000, accuracy: 0.001)
    }

    func testTenSecondGapStillCountsAsAnHonestPeak() {
        // The gate is inclusive at the ten-second boundary: a delta measured over exactly ten seconds is
        // still a live reading, so it may hold a peak. 1,000,000 bytes over 10s = 100,000 B/s raw, a
        // first EMA step halves it to 50,000.
        let bridge = build(
            current: snap([.networkBytesIn: 1_000_000], at: t0.addingTimeInterval(10)),
            previous: snap([.networkBytesIn: 0], at: t0)
        )
        XCTAssertEqual(channel(bridge, .traffic).peak, 50_000, accuracy: 0.001)
    }

    // MARK: - Availability tags

    func testAvailabilityTagMapping() {
        var availability = running
        availability[.ai] = .sourceMissing
        availability[.input] = .needsPermission
        availability[.disk] = nil // absent from the map -> defaults to disabled

        let bridge = build(current: snap([:], at: t0), availability: availability)

        let cognition = channel(bridge, .cognition)
        XCTAssertEqual(cognition.uncalibratedTag, "UNCALIBRATED — NO LOCAL SRC")
        XCTAssertFalse(cognition.needsPermission)

        let mechanics = channel(bridge, .mechanics)
        XCTAssertEqual(mechanics.uncalibratedTag, "UNCALIBRATED")
        XCTAssertTrue(mechanics.needsPermission)

        let traffic = channel(bridge, .traffic)
        XCTAssertNil(traffic.uncalibratedTag)
        XCTAssertFalse(traffic.needsPermission)

        XCTAssertEqual(channel(bridge, .storage).uncalibratedTag, "UNCALIBRATED")
    }

    func testUncalibratedChannelStillMovesItsBars() {
        // A source-missing / permission-gated channel degrades honestly: bars still reflect whatever
        // history exists rather than flatlining.
        var availability = running
        availability[.input] = .needsPermission
        let mechanics = channel(
            build(current: snap([:], at: t0),
                  series: [.inputKeystrokes: [0, 120]], availability: availability),
            .mechanics
        )
        XCTAssertEqual(mechanics.bars[1], 1.0, accuracy: 0.0001)
    }

    // MARK: - Sub-lines and exposure

    func testSublinesCarryDirectionalTotals() {
        let totals: [MetricKind: Int64] = [
            .networkBytesIn: 2_000, .networkBytesOut: 500,
            .diskBytesRead: 1_000, .diskBytesWritten: 3_000,
            .aiInputTokens: 1_000, .aiOutputTokens: 4_000,
            .inputKeystrokes: 8_000, .inputMouseMilliPixels: 8_661_417,
        ]
        let bridge = build(current: snap(totals, at: t0))

        XCTAssertEqual(channel(bridge, .traffic).subline,
                       "down \(ByteFormatting.bytes(2_000)) / up \(ByteFormatting.bytes(500))")
        XCTAssertEqual(channel(bridge, .storage).subline,
                       "read \(ByteFormatting.bytes(1_000)) / write \(ByteFormatting.bytes(3_000))")
        XCTAssertEqual(channel(bridge, .cognition).subline,
                       "in \(ByteFormatting.tokens(1_000)) / out \(ByteFormatting.tokens(4_000)) tok")
        XCTAssertEqual(channel(bridge, .mechanics).subline,
                       "\(ByteFormatting.grouped(8_000)) keys / \(ByteFormatting.distanceHauled(milliPixels: 8_661_417))")
    }

    func testExposureAccumulatesDurationAndDayFractionWithoutARate() {
        let bridge = build(current: snap([.screenAttentiveSeconds: 3_720], at: t0))
        let exposure = channel(bridge, .exposure)
        XCTAssertEqual(exposure.rate, 0)
        XCTAssertEqual(exposure.rateReadout, "")
        XCTAssertNil(exposure.peakPosition)
        XCTAssertEqual(exposure.exposureReadout, ByteFormatting.duration(seconds: 3_720))
        XCTAssertEqual(exposure.exposureFraction, 3_720.0 / 86_400.0, accuracy: 0.0001)
        XCTAssertEqual(exposure.subline, "4.3% of 24h")
    }

    func testExposureBarsScaleAttentiveSecondsPerMinute() {
        // A fully-attentive minute (60s) fills the bar; a half-attended minute reads half.
        let series: [MetricKind: [Int64]] = [.screenAttentiveSeconds: [30, 60]]
        let bars = channel(build(current: snap([:], at: t0), series: series), .exposure).bars
        XCTAssertEqual(bars[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(bars[1], 1.0, accuracy: 0.0001)
    }

    // MARK: - Readout formatting per channel unit

    func testChannelReadoutsUseTheirNativeUnit() {
        let mechanics = channel(
            build(current: snap([.inputKeystrokes: 84], at: t0.addingTimeInterval(60)),
                  previous: snap([.inputKeystrokes: 0], at: t0)),
            .mechanics
        )
        // 84 keys over 60s = 84 keys/min raw; first EMA step halves to 42.
        XCTAssertEqual(mechanics.rate, 42, accuracy: 0.001)
        XCTAssertEqual(mechanics.rateReadout, "42 kpm")
    }

    // MARK: - Liveness and the EMA zero snap

    func testIdleDecaySnapsToExactZeroAndGoesNotLive() {
        // Start from a real rate, then poll with no traffic: the EMA halves per tick and must snap to
        // exactly 0 once well under the liveness threshold, instead of asymptoting forever.
        var state = MeterState(smoothedRate: [.traffic: 100_000], peakRate: [.traffic: 100_000])
        var live = true
        for i in 1...20 {
            let bridge = build(
                current: snap([.networkBytesIn: 0], at: t0.addingTimeInterval(Double(i) * 2)),
                previous: snap([.networkBytesIn: 0], at: t0.addingTimeInterval(Double(i - 1) * 2)),
                priorState: state
            )
            state = bridge.state
            live = channel(bridge, .traffic).isLive
        }
        XCTAssertEqual(state.smoothedRate[.traffic], 0)
        XCTAssertFalse(live)
        // The session peak survives the decay untouched.
        XCTAssertEqual(state.peakRate[.traffic] ?? 0, 100_000, accuracy: 0.001)
    }

    func testIsLiveGatesOnThresholdNotStrictNonzero() {
        // 400 B/s smoothed is under the 512 B/s traffic threshold: real but idle-level, so not live.
        let below = build(
            current: snap([.networkBytesIn: 1_600], at: t0.addingTimeInterval(2)),
            previous: snap([.networkBytesIn: 0], at: t0)
        )
        XCTAssertFalse(channel(below, .traffic).isLive)

        let above = build(
            current: snap([.networkBytesIn: 200_000], at: t0.addingTimeInterval(2)),
            previous: snap([.networkBytesIn: 0], at: t0)
        )
        XCTAssertTrue(channel(above, .traffic).isLive)
        XCTAssertTrue(above.anyLive)
    }

    func testResettingSmoothingKeepsPeaksAndForgetsRates() {
        let state = MeterState(smoothedRate: [.traffic: 5_000], peakRate: [.traffic: 9_000])
        let reset = state.resettingSmoothing()
        XCTAssertTrue(reset.smoothedRate.isEmpty)
        XCTAssertEqual(reset.peakRate[.traffic], 9_000)

        // Built from a reset state with no previous snapshot, the reopened first tick reads zero rate
        // (no phantom decay) while the peak readout stands.
        let bridge = build(current: snap([.networkBytesIn: 1_000_000], at: t0), priorState: reset)
        let traffic = channel(bridge, .traffic)
        XCTAssertEqual(traffic.rate, 0)
        XCTAssertFalse(traffic.isLive)
        XCTAssertEqual(traffic.peak, 9_000, accuracy: 0.001)
    }

    // MARK: - Chart feeds

    func testRawBarsCarryAbsoluteRateAxisValues() {
        // 6 MB in one minute is 100 KB/s on the byte-rate axis; rawBars keep that absolute value while
        // bars normalize it to the window max, so cross-channel charts can share one scale.
        let series: [MetricKind: [Int64]] = [.networkBytesIn: [6_000_000, 0]]
        let traffic = channel(build(current: snap([:], at: t0), series: series), .traffic)
        XCTAssertEqual(traffic.rawBars[0], 100_000, accuracy: 0.001)
        XCTAssertEqual(traffic.rawBars[1], 0)
        XCTAssertEqual(traffic.bars[0], 1.0, accuracy: 0.0001)
    }

    func testCognitionCarriesTokenSplitAndOthersDoNot() {
        let bridge = build(current: snap([.aiInputTokens: 1_720, .aiOutputTokens: 9_236], at: t0))
        XCTAssertEqual(channel(bridge, .cognition).tokenSplit,
                       TokenSplit(payable: 1_720, receivable: 9_236))
        XCTAssertNil(channel(bridge, .traffic).tokenSplit)
        XCTAssertNil(channel(bridge, .exposure).tokenSplit)
    }
}
