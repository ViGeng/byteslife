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
        priorState: MeterState = .initial,
        windows: [MeterChannelKind: MeterWindow] = [:],
        heroWindow: MeterWindow = .default
    ) -> MeterBridge {
        MeterBridge.build(
            current: current,
            previous: previous,
            series: series,
            availabilityByFamily: availability ?? running,
            priorState: priorState,
            windows: windows,
            heroWindow: heroWindow
        )
    }

    /// Pads a short per-minute fixture to a full window length with TRAILING zeros, so the given values
    /// keep their index positions. The bucketizer left-pads a history shorter than the window, which would
    /// otherwise shift a short fixture into the most recent buckets; a full-length input avoids that so a
    /// fixture's `bars[0]` still maps to its first minute. `count` is the default 30M window's minute span.
    private func fill(_ values: [Int64], to count: Int = 30) -> [Int64] {
        values + [Int64](repeating: 0, count: max(0, count - values.count))
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
        let series: [MetricKind: [Int64]] = [.networkBytesIn: fill([6_000, 6_000, 6_000])]
        let traffic = channel(build(current: snap([:], at: t0), series: series), .traffic)
        // The default 30M window is 30 one-minute buckets.
        XCTAssertEqual(traffic.bars.count, 30)
        XCTAssertLessThan(traffic.bars.max()!, 0.01)
    }

    func testSingleSpikeWindowPinsOnlyTheSpikeToFull() {
        // One 6,553,600-byte minute -> ~109 KB/s, above the floor and the sole window maximum.
        let series: [MetricKind: [Int64]] = [.networkBytesIn: fill([0, 6_553_600, 0])]
        let bars = channel(build(current: snap([:], at: t0), series: series), .traffic).bars
        XCTAssertEqual(bars[0], 0, accuracy: 0.0001)
        XCTAssertEqual(bars[1], 1.0, accuracy: 0.0001)
        XCTAssertEqual(bars[2], 0, accuracy: 0.0001)
    }

    func testCognitionBarsUsePerMinuteBucketsDirectly() {
        // Token buckets are already per-minute, so a 300-token minute against a 600-token window max
        // reads exactly half a bar with no per-second division.
        let series: [MetricKind: [Int64]] = [.aiInputTokens: fill([300, 600]), .aiOutputTokens: fill([0, 0])]
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

    func testRegrantFamilyEngravesStaleGrantTag() {
        var availability = running
        availability[.input] = .needsPermission

        // Without a regrant flag the mechanics channel reads the generic tag.
        let ordinary = MeterBridge.build(
            current: snap([:], at: t0), previous: nil, series: [:],
            availabilityByFamily: availability, priorState: .initial
        )
        XCTAssertEqual(channel(ordinary, .mechanics).uncalibratedTag, "UNCALIBRATED")

        // Flagging input as a stale grant swaps in the re-grant tag while still showing the affordance.
        let flagged = MeterBridge.build(
            current: snap([:], at: t0), previous: nil, series: [:],
            availabilityByFamily: availability, priorState: .initial,
            regrantFamilies: [.input]
        )
        let mechanics = channel(flagged, .mechanics)
        XCTAssertEqual(mechanics.uncalibratedTag, "RE-GRANT — SIGNATURE CHANGED")
        XCTAssertTrue(mechanics.needsPermission)
        // A regrant flag on a channel that is not needs-permission never changes its tag.
        XCTAssertNil(channel(flagged, .traffic).uncalibratedTag)
    }

    func testUncalibratedChannelStillMovesItsBars() {
        // A source-missing / permission-gated channel degrades honestly: bars still reflect whatever
        // history exists rather than flatlining.
        var availability = running
        availability[.input] = .needsPermission
        let mechanics = channel(
            build(current: snap([:], at: t0),
                  series: [.inputKeystrokes: fill([0, 120])], availability: availability),
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
        // MECHANICS carries keys, clicks, its live cadence peak (0 with no prior snapshot), and distance.
        XCTAssertEqual(channel(bridge, .mechanics).subline,
                       "\(ByteFormatting.grouped(8_000)) keys · \(ByteFormatting.grouped(0)) clicks · "
                       + "peak \(ByteFormatting.keyRate(0)) · \(ByteFormatting.distanceHauled(milliPixels: 8_661_417))")
    }

    func testMechanicsSublineCarriesClicksAndCadencePeak() {
        // A 28-key delta over a 10s (short, peak-eligible) gap is 168 keys/min raw; the first EMA step
        // halves it to 84, which the session peak-hold records and the sub-line reads as "peak 84 kpm".
        // The sub-line's key figure is today's TOTAL keystrokes (168), independent of the delta, and its
        // click figure comes straight from today's totals.
        let mechanics = channel(
            build(current: snap([.inputKeystrokes: 168, .inputClicks: 210,
                                 .inputMouseMilliPixels: 121_260], at: t0.addingTimeInterval(10)),
                  previous: snap([.inputKeystrokes: 140], at: t0)),
            .mechanics
        )
        XCTAssertEqual(mechanics.peak, 84, accuracy: 0.001)
        XCTAssertEqual(mechanics.subline,
                       "168 keys · 210 clicks · peak 84 kpm · \(ByteFormatting.distanceHauled(milliPixels: 121_260))")
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
        let series: [MetricKind: [Int64]] = [.screenAttentiveSeconds: fill([30, 60])]
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
        let series: [MetricKind: [Int64]] = [.networkBytesIn: fill([6_000_000, 0])]
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

    // MARK: - Adjustable chart windows

    /// An all-zero per-minute fixture of the given length, for placing signal at exact minute indices.
    private func zeros(_ length: Int) -> [Int64] { [Int64](repeating: 0, count: length) }

    func testMeterWindowSpecMatchesThePlan() {
        XCTAssertEqual(MeterWindow.allCases, [.w30m, .h1, .h6, .h24])
        XCTAssertEqual(MeterWindow.w30m.totalMinutes, 30);  XCTAssertEqual(MeterWindow.w30m.bucketMinutes, 1)
        XCTAssertEqual(MeterWindow.h1.totalMinutes, 60);    XCTAssertEqual(MeterWindow.h1.bucketMinutes, 2)
        XCTAssertEqual(MeterWindow.h6.totalMinutes, 360);   XCTAssertEqual(MeterWindow.h6.bucketMinutes, 10)
        XCTAssertEqual(MeterWindow.h24.totalMinutes, 1440); XCTAssertEqual(MeterWindow.h24.bucketMinutes, 30)
        XCTAssertEqual(MeterWindow.allCases.map(\.bucketCount), [30, 30, 36, 48])
        XCTAssertEqual(MeterWindow.allCases.map(\.token), ["30M", "1H", "6H", "24H"])
        XCTAssertEqual(MeterWindow.default, .w30m)
    }

    func testWindowAggregatesMinutesAcrossBucketBoundaries() {
        // 1H: 60 minutes summed pairwise into 30 two-minute buckets. Two adjacent minutes land in one
        // bucket; the boundary falls between minute pairs, so minute 1 and minute 2 are in DIFFERENT
        // buckets.
        var m = zeros(60)
        m[0] = 120; m[1] = 180   // bucket 0 sum 300
        m[2] = 60                // bucket 1 sum 60
        m[58] = 240; m[59] = 60  // bucket 29 sum 300
        let series: [MetricKind: [Int64]] = [.aiInputTokens: m, .aiOutputTokens: zeros(60)]
        let cognition = channel(
            build(current: snap([:], at: t0), series: series, windows: [.cognition: .h1]), .cognition)
        XCTAssertEqual(cognition.rawBars.count, 30)
        // Cognition is per-minute: bucket sum / bucket minutes (2). 300/2 = 150, 60/2 = 30 tok/min.
        XCTAssertEqual(cognition.rawBars[0], 150, accuracy: 0.001)
        XCTAssertEqual(cognition.rawBars[1], 30, accuracy: 0.001)
        XCTAssertEqual(cognition.rawBars[29], 150, accuracy: 0.001)
    }

    func testRateAxisConversionPerSecondChannelAt1HAnd24H() {
        // Per-second channels divide a bucket's byte sum by its seconds. 1H bucket = 2 min = 120 s;
        // 24H bucket = 30 min = 1800 s. The floor and peak axis stay bytes/s regardless of zoom.
        var m1 = zeros(60)
        m1[58] = 120_000; m1[59] = 120_000  // most recent 2-min bucket sums 240,000 -> /120 = 2000 B/s
        let t1 = channel(
            build(current: snap([:], at: t0),
                  series: [.networkBytesIn: m1, .networkBytesOut: zeros(60)],
                  windows: [.traffic: .h1]), .traffic)
        XCTAssertEqual(t1.rawBars.count, 30)
        XCTAssertEqual(t1.rawBars[29], 2000, accuracy: 0.001)

        var m24 = zeros(1440)
        for i in 0..<30 { m24[i] = 60_000 }  // first 30-min bucket sums 1,800,000 -> /1800 = 1000 B/s
        let t24 = channel(
            build(current: snap([:], at: t0),
                  series: [.networkBytesIn: m24, .networkBytesOut: zeros(1440)],
                  windows: [.traffic: .h24]), .traffic)
        XCTAssertEqual(t24.rawBars.count, 48)
        XCTAssertEqual(t24.rawBars[0], 1000, accuracy: 0.001)
    }

    func testRateAxisConversionPerMinuteChannelAt1HAnd24H() {
        // Per-minute channels divide a bucket's sum by its minutes: 1H by 2, 24H by 30.
        var m1 = zeros(60)
        m1[0] = 100; m1[1] = 200  // bucket 0 sum 300 -> /2 = 150 kpm
        let mech1 = channel(
            build(current: snap([:], at: t0),
                  series: [.inputKeystrokes: m1], windows: [.mechanics: .h1]), .mechanics)
        XCTAssertEqual(mech1.rawBars[0], 150, accuracy: 0.001)

        var m24 = zeros(1440)
        for i in 0..<30 { m24[i] = 60 }  // bucket 0 sum 1800 -> /30 = 60 kpm
        let mech24 = channel(
            build(current: snap([:], at: t0),
                  series: [.inputKeystrokes: m24], windows: [.mechanics: .h24]), .mechanics)
        XCTAssertEqual(mech24.rawBars.count, 48)
        XCTAssertEqual(mech24.rawBars[0], 60, accuracy: 0.001)
    }

    func testFloorBehaviorUnchangedAt30M() {
        // At 30M the window is 30 one-minute buckets and the byte floor is 64 KB/s. A window whose whole
        // signal sits below the floor stays flat: the floor is the denominator, not the window max.
        var quiet = zeros(30)
        quiet[0] = 60_000  // 1000 B/s, well under the 65,536 B/s floor
        let traffic = channel(
            build(current: snap([:], at: t0),
                  series: [.networkBytesIn: quiet, .networkBytesOut: zeros(30)],
                  windows: [.traffic: .w30m]), .traffic)
        XCTAssertEqual(traffic.bars.count, 30)
        XCTAssertEqual(traffic.bars[0], 1000.0 / 65_536.0, accuracy: 0.0001)
    }

    func testExposureFractionInThirtyMinuteBuckets() {
        // 24H: 48 buckets of 30 minutes. EXPOSURE keeps an ABSOLUTE scale: a bar reads attentive seconds
        // per bucket over the bucket's capacity (30 min = 1800 s), never normalized to a busy window.
        var attentive = zeros(1440)
        for i in 0..<30 { attentive[i] = 30 }   // bucket 0: 900 attentive s over 1800 capacity = 0.5
        for i in 30..<60 { attentive[i] = 60 }  // bucket 1: fully attentive = 1.0
        let exposure = channel(
            build(current: snap([:], at: t0),
                  series: [.screenAttentiveSeconds: attentive], windows: [.exposure: .h24]), .exposure)
        XCTAssertEqual(exposure.bars.count, 48)
        XCTAssertEqual(exposure.bars[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(exposure.bars[1], 1.0, accuracy: 0.0001)
        // The full bucket did not push the half-full bucket down: the scale is absolute, not window-relative.
    }

    func testRaggedShortHistoryPadsWithZeros() {
        // Fewer recorded minutes than the window: the missing older minutes read as zero, so the signal
        // lands in the most recent buckets and the older buckets stay empty. Four minutes into a 1H
        // window (60 minutes, 2-minute buckets) fill only the last two buckets.
        let series: [MetricKind: [Int64]] = [
            .aiInputTokens: [10, 20, 30, 40],
            .aiOutputTokens: [0, 0, 0, 0],
        ]
        let cognition = channel(
            build(current: snap([:], at: t0), series: series, windows: [.cognition: .h1]), .cognition)
        XCTAssertEqual(cognition.rawBars.count, 30)
        XCTAssertTrue(cognition.rawBars.prefix(28).allSatisfy { $0 == 0 })
        // The four real minutes fill the final two 2-minute buckets: (10+20)/2 = 15, (30+40)/2 = 35.
        XCTAssertEqual(cognition.rawBars[28], 15, accuracy: 0.001)
        XCTAssertEqual(cognition.rawBars[29], 35, accuracy: 0.001)
    }

    func testHeroSeriesUsesTheHeroWindowIndependentOfChannelWindows() {
        // The hero flow chart carries its own window. With the TRAFFIC card at 30M but the hero at 1H, the
        // hero traffic series buckets at 2 minutes while the card's rawBars bucket at 1.
        var m = zeros(60)
        m[58] = 120_000; m[59] = 120_000
        let bridge = build(
            current: snap([:], at: t0),
            series: [.networkBytesIn: m, .networkBytesOut: zeros(60)],
            windows: [.traffic: .w30m], heroWindow: .h1)
        XCTAssertEqual(bridge.heroTraffic.count, 30)                        // 1H -> 30 buckets
        XCTAssertEqual(bridge.heroTraffic[29], 2000, accuracy: 0.001)      // 240,000 / 120 s
        XCTAssertEqual(bridge.heroStorage.count, 30)                       // paired, all zero here
        XCTAssertTrue(bridge.heroStorage.allSatisfy { $0 == 0 })
        // The TRAFFIC card meanwhile buckets the most recent 30 minutes at one-minute resolution.
        XCTAssertEqual(channel(bridge, .traffic).rawBars.count, 30)
    }

    func testDefaultWindowKeepsThirtyOneMinuteBuckets() {
        // With no window map the build falls back to 30M for every channel and the hero, so a caller that
        // never adjusts a window sees the shipped 30 one-minute buckets.
        let series: [MetricKind: [Int64]] = [.networkBytesIn: zeros(30), .networkBytesOut: zeros(30)]
        let bridge = build(current: snap([:], at: t0), series: series)
        XCTAssertEqual(channel(bridge, .traffic).rawBars.count, 30)
        XCTAssertEqual(bridge.heroTraffic.count, 30)
    }
}
