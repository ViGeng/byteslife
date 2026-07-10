import Foundation

/// The five instrument channels of the Meter Bridge, in the concept sheet's reading order. Raw string
/// values are stable identifiers; the titles are the concept's exact engraved channel names.
public enum MeterChannelKind: String, CaseIterable, Sendable {
    case traffic
    case storage
    case cognition
    case exposure
    case mechanics

    /// The engraved channel label shown on the faceplate.
    public var title: String {
        switch self {
        case .traffic: return "TRAFFIC"
        case .storage: return "STORAGE"
        case .cognition: return "COGNITION"
        case .exposure: return "EXPOSURE"
        case .mechanics: return "MECHANICS"
        }
    }

    /// The collector family whose availability drives this channel's calibration tag.
    public var family: MetricFamily {
        switch self {
        case .traffic: return .network
        case .storage: return .disk
        case .cognition: return .ai
        case .exposure: return .screen
        case .mechanics: return .input
        }
    }

    /// The metric kinds combined into this channel's history bars. EXPOSURE reads attentive seconds; the
    /// four rate channels read their two (or one) throughput kinds.
    public var seriesKinds: [MetricKind] {
        switch self {
        case .traffic: return [.networkBytesIn, .networkBytesOut]
        case .storage: return [.diskBytesRead, .diskBytesWritten]
        case .cognition: return [.aiInputTokens, .aiOutputTokens]
        case .exposure: return [.screenAttentiveSeconds]
        case .mechanics: return [.inputKeystrokes]
        }
    }

    /// The metric kinds whose snapshot delta feeds the live rate. EXPOSURE has no rate, so it is empty.
    /// COGNITION deliberately excludes cache tokens, matching the ledger's exchange-rate reasoning.
    public var rateKinds: [MetricKind] {
        self == .exposure ? [] : seriesKinds
    }

    /// Whether the channel's rate and bars are expressed per second (TRAFFIC, STORAGE) rather than per
    /// minute. A per-second channel divides each minute bucket by 60 to place it on the rate axis.
    public var isPerSecond: Bool {
        self == .traffic || self == .storage
    }

    /// The minimum full-scale used to normalize the bars, expressed in the channel's rate axis unit.
    /// It keeps an idle window from amplifying stray noise into a full bar: when the window maximum is
    /// below this floor, the floor becomes the denominator instead.
    /// - TRAFFIC / STORAGE: 65,536 B/s (64 KB/s). Below a sustained 64 KB/s a byte channel is idle.
    /// - COGNITION: 100 tok/min, a light trickle of thinking.
    /// - MECHANICS: 60 keys/min, roughly one key per second, a slow idle cadence.
    /// - EXPOSURE: 60 attentive-seconds/min, one fully-present minute, the natural full scale.
    public var normalizationFloor: Double {
        switch self {
        case .traffic, .storage: return 65_536
        case .cognition: return 100
        case .mechanics: return 60
        case .exposure: return 60
        }
    }

    /// The smoothed rate at or above which the channel counts as live. Every live-gated light (glow,
    /// pulse, the panel's LIVE chip) reads `isLive`, never a raw `rate > 0`: the EMA only asymptotes
    /// toward zero, so a strict nonzero test would latch live forever after the last real byte.
    /// COGNITION's threshold applies to its trailing-window rate, so it reads live while any tokens
    /// landed within the window. EXPOSURE carries no rate and is never "live" in this sense.
    public var livenessThreshold: Double {
        switch self {
        case .traffic, .storage: return 512    // half a KB/s: below this a byte channel reads idle
        case .cognition: return 1              // one token per minute
        case .mechanics: return 1              // one keystroke per minute
        case .exposure: return .infinity
        }
    }
}

/// COGNITION's prompted-versus-generated token split for the ratio bar, today's raw counts.
public struct TokenSplit: Equatable, Sendable {
    public let payable: Int64
    public let receivable: Int64

    public init(payable: Int64, receivable: Int64) {
        self.payable = payable
        self.receivable = receivable
    }
}

/// One totals reading paired with the wall-clock instant it was taken. The Meter Bridge computes a live
/// rate from the delta between two of these over their timestamp gap, so the model stays clock-injectable
/// (the only clock it sees is the timestamps its caller supplies).
public struct MeterSnapshot: Equatable, Sendable {
    public let totals: [MetricKind: Int64]
    public let timestamp: Date

    public init(totals: [MetricKind: Int64], timestamp: Date) {
        self.totals = totals
        self.timestamp = timestamp
    }
}

/// One reading in COGNITION's trailing-window trail: a wall-clock instant paired with the day's
/// cumulative input+output token total at that instant (cache tokens excluded, per the ledger's
/// exchange-rate reasoning).
public struct TokenTrailPoint: Equatable, Sendable {
    public let timestamp: Date
    public let total: Int64

    public init(timestamp: Date, total: Int64) {
        self.timestamp = timestamp
        self.total = total
    }
}

/// The carry state threaded between successive builds: each channel's last smoothed rate (the EMA's
/// previous value), its session peak-hold, the peak-only EMA that feeds it, and COGNITION's trailing
/// token trail. The view model holds one of these and feeds it back in on every poll; it starts empty
/// and resets to empty on relaunch (peak-hold is per-session in v1).
public struct MeterState: Equatable, Sendable {
    public let smoothedRate: [MeterChannelKind: Double]
    public let peakRate: [MeterChannelKind: Double]
    /// The peak-only EMA: it integrates exclusively short-gap measurements and resets to zero whenever a
    /// long gap breaks the chain, so a background or gap average can never launder its residue into a
    /// session peak through the display EMA's carry. COGNITION keeps this at zero: its windowed rate is
    /// already a sustained figure, so its peak needs no gap gate.
    public let peakSmoothed: [MeterChannelKind: Double]
    /// COGNITION's trail of recent (timestamp, input+output total) readings, spanning the trailing
    /// window plus one anchor point at or beyond the boundary. AI tools land tokens in bursts at message
    /// completion, so a 2-second-delta EMA reads one absurd spike then idle; the windowed rate over this
    /// trail reads steady across the burst-then-gap pattern instead.
    public let tokenTrail: [TokenTrailPoint]

    public init(smoothedRate: [MeterChannelKind: Double] = [:],
                peakRate: [MeterChannelKind: Double] = [:],
                peakSmoothed: [MeterChannelKind: Double] = [:],
                tokenTrail: [TokenTrailPoint] = []) {
        self.smoothedRate = smoothedRate
        self.peakRate = peakRate
        self.peakSmoothed = peakSmoothed
        self.tokenTrail = tokenTrail
    }

    /// The launch state: no prior smoothing, no peaks held.
    public static let initial = MeterState()

    /// The state to carry across a panel close and reopen: smoothing forgets, peaks persist. A reopened
    /// panel must cold-start its rates at zero (the first tick has no honest 2-second delta to show), but
    /// the session peak-hold is a fact about the session, not about the panel being open. The token trail
    /// forgets too: after a cold gap its points describe a window nobody watched, so COGNITION's windowed
    /// rate rebuilds from a fresh trail exactly like the EMAs.
    public func resettingSmoothing() -> MeterState {
        MeterState(smoothedRate: [:], peakRate: peakRate, peakSmoothed: [:], tokenTrail: [])
    }
}

/// One rendered channel of the Meter Bridge: its live rate, its normalized history bars, its peak-hold
/// mark, its directional sub-line, and its calibration tag. All figures are formatted and locale-free, so
/// the whole struct is covered by `swift test` without a clock, locale, or I/O.
public struct MeterChannel: Equatable, Sendable, Identifiable {
    public let kind: MeterChannelKind
    /// The channel's family availability, straight from the registry snapshot.
    public let availability: Availability
    /// The engraved calibration tag to overlay, or nil when the channel reads live. A source-missing
    /// COGNITION reads "UNCALIBRATED — NO LOCAL SRC"; a permission-gated channel reads "UNCALIBRATED".
    public let uncalibratedTag: String?
    /// True when the UI should show the permission-grant affordance (a needs-permission channel).
    public let needsPermission: Bool
    /// Recent minute buckets normalized to 0-1 against the window range with a floor, oldest first.
    public let bars: [Double]
    /// The same minutes on the channel's absolute rate axis (bytes/s, tok/min, keys/min), oldest first;
    /// `bars` stays the per-channel floored shape.
    public let rawBars: [Double]
    /// True when the smoothed rate is at or above the channel's liveness threshold. Every live-gated
    /// light reads this, never a raw nonzero test.
    public let isLive: Bool
    /// COGNITION only: today's token split for the ratio bar. Nil on every other channel.
    public let tokenSplit: TokenSplit?
    /// Today's directional totals, e.g. "down 1.2 GB / up 300 MB".
    public let subline: String

    /// The smoothed live rate in the channel's native unit (bytes/s, tokens/min, keys/min). 0 for EXPOSURE.
    public let rate: Double
    /// The formatted live rate, e.g. "2.1 MB/s", "312 tok/min", "42 kpm". Empty for EXPOSURE.
    public let rateReadout: String
    /// The session peak smoothed rate in native units. 0 for EXPOSURE.
    public let peak: Double
    /// The formatted peak readout shown beside the cyan tick. Empty for EXPOSURE.
    public let peakReadout: String
    /// The peak's position 0-1 on the current bar range, for the cyan tick. Nil when no peak yet or EXPOSURE.
    public let peakPosition: Double?

    /// EXPOSURE only: accumulated attentive time as a 0-1 fraction of a 24h day, for the outer arc. 0 for
    /// the other channels.
    public let exposureFraction: Double
    /// EXPOSURE only: the accumulated attentive duration, e.g. "3h 24m". Empty for the other channels.
    public let exposureReadout: String

    public var id: String { kind.rawValue }
    public var title: String { kind.title }

    public init(kind: MeterChannelKind, availability: Availability, uncalibratedTag: String?,
                needsPermission: Bool, bars: [Double], rawBars: [Double], isLive: Bool,
                tokenSplit: TokenSplit?, subline: String, rate: Double,
                rateReadout: String, peak: Double, peakReadout: String, peakPosition: Double?,
                exposureFraction: Double, exposureReadout: String) {
        self.kind = kind
        self.availability = availability
        self.uncalibratedTag = uncalibratedTag
        self.needsPermission = needsPermission
        self.bars = bars
        self.rawBars = rawBars
        self.isLive = isLive
        self.tokenSplit = tokenSplit
        self.subline = subline
        self.rate = rate
        self.rateReadout = rateReadout
        self.peak = peak
        self.peakReadout = peakReadout
        self.peakPosition = peakPosition
        self.exposureFraction = exposureFraction
        self.exposureReadout = exposureReadout
    }
}

/// The pure, clock-injectable model behind the Meter Bridge panel. It turns two totals snapshots, the
/// per-kind minute history, the availability map, and the carried-in state into five rendered channels
/// plus a new carry state to thread into the next poll. No clock, locale, or I/O of its own.
public struct MeterBridge: Equatable, Sendable {
    /// The five channels in concept order: TRAFFIC, STORAGE, COGNITION, EXPOSURE, MECHANICS.
    public let channels: [MeterChannel]
    /// The smoothing and peak-hold state to feed back into the next build.
    public let state: MeterState

    public init(channels: [MeterChannel], state: MeterState) {
        self.channels = channels
        self.state = state
    }

    /// True when any channel reads live: the panel's LIVE chip and combined-flow line light on this.
    public var anyLive: Bool { channels.contains(where: \.isLive) }

    /// The combined TRAFFIC + STORAGE smoothed rate in bytes/s, for the header's flow line.
    public var combinedByteRate: Double {
        channels.filter { $0.kind == .traffic || $0.kind == .storage }.map(\.rate).reduce(0, +)
    }

    /// The EMA weight on the newest raw rate. In the concept's 0.4-0.6 band: heavy enough to track real
    /// throughput swings, light enough to damp the twitch of a 2-second poll.
    public static let emaAlpha = 0.5

    /// The longest inter-snapshot gap over which a delta still counts as an honest live reading for
    /// peak-hold. The open 2-second poll qualifies; the 30-second background carry and a wake-from-sleep
    /// gap do not. A long gap still yields a truthful recent average for the smoothed rate, but its gap
    /// average must never forge a session peak. Ten seconds spans the open cadence with room to spare
    /// while excluding the background tick.
    public static let peakMaxElapsed: TimeInterval = 10

    /// The trailing window COGNITION's live rate is measured over, in seconds. Agentic sessions land
    /// tokens every few seconds to a minute, so 90 seconds reads steady across the landing gaps while
    /// still decaying to zero about a minute and a half after the last landing.
    public static let cognitionWindowSeconds: TimeInterval = 90

    /// The tag a permission-gated or otherwise uncalibrated channel engraves.
    public static let uncalibratedTag = "UNCALIBRATED"
    /// The tag a source-missing COGNITION channel engraves (no local AI log to read).
    public static let cognitionUncalibratedTag = "UNCALIBRATED — NO LOCAL SRC"
    /// The tag a needs-permission channel engraves when its permission grant went stale under a changed
    /// code-signing identity: the tap reports running but delivers nothing, so re-granting is the fix.
    public static let regrantTag = "RE-GRANT — SIGNATURE CHANGED"

    /// Every metric kind the Meter Bridge reads, for the view model to fetch in one `minuteSeries` call.
    public static let trackedKinds: [MetricKind] = MeterChannelKind.allCases.flatMap(\.seriesKinds)

    /// Builds the five channels from the current totals snapshot, the previous snapshot (nil on the first
    /// poll), the per-kind minute series, the family availability map, and the prior carry state.
    /// - Parameter regrantFamilies: families whose needs-permission state is a stale-grant flag rather
    ///   than a first-time prompt. Such a channel engraves `regrantTag` instead of `uncalibratedTag`,
    ///   steering the user to re-grant the permission. Empty by default, so callers that never detect a
    ///   stale grant keep the ordinary UNCALIBRATED tag.
    /// - Parameter windows: the per-channel history window. A channel absent from the map falls back to
    ///   the 30M default, so callers that never adjust a window keep the shipped 30 one-minute buckets.
    public static func build(
        current: MeterSnapshot,
        previous: MeterSnapshot?,
        series: [MetricKind: [Int64]],
        availabilityByFamily: [MetricFamily: Availability],
        priorState: MeterState,
        regrantFamilies: Set<MetricFamily> = [],
        windows: [MeterChannelKind: MeterWindow] = [:]
    ) -> MeterBridge {
        // The fetched minute history is oldest-first; each channel reads the most recent slice its own
        // window spans, so combine to the full fetched length and let the bucketizer take the tail.
        let seriesLength = series.values.map(\.count).max() ?? 0

        var channels: [MeterChannel] = []
        var smoothedOut: [MeterChannelKind: Double] = [:]
        var peakOut: [MeterChannelKind: Double] = [:]
        var peakSmoothedOut: [MeterChannelKind: Double] = [:]
        var trailOut = priorState.tokenTrail

        for kind in MeterChannelKind.allCases {
            let availability = availabilityByFamily[kind.family] ?? .disabled
            let (tag, needsPermission) = calibration(
                kind: kind, availability: availability, regrant: regrantFamilies.contains(kind.family)
            )
            let window = windows[kind] ?? .default
            let minutes = combine(series: series, kinds: kind.seriesKinds, length: seriesLength)
            let rawBars = rateAxisBuckets(minutes: minutes, kind: kind, window: window)
            let (bars, denominator) = normalize(rateValues: rawBars, floor: kind.normalizationFloor)

            if kind == .exposure {
                let attentive = current.totals[.screenAttentiveSeconds] ?? 0
                let fraction = min(1.0, max(0.0, Double(attentive) / 86_400))
                channels.append(MeterChannel(
                    kind: kind, availability: availability, uncalibratedTag: tag,
                    needsPermission: needsPermission, bars: bars, rawBars: rawBars,
                    isLive: false, tokenSplit: nil,
                    subline: subline(kind: kind, totals: current.totals, exposureFraction: fraction),
                    rate: 0, rateReadout: "", peak: 0, peakReadout: "", peakPosition: nil,
                    exposureFraction: fraction,
                    exposureReadout: ByteFormatting.duration(seconds: attentive)
                ))
                continue
            }

            let priorPeak = priorState.peakRate[kind] ?? 0
            var smoothed: Double
            var peakSmoothed: Double
            let peak: Double
            if kind == .cognition {
                // COGNITION reads a trailing-window rate, not a delta EMA: AI tools book usage only at
                // message completion, so tokens land in bursts and a 2-second delta is one absurd spike
                // followed by a fast decay to idle. Tokens landed over the trailing window read steady
                // across the burst-then-gap landing pattern and decay honestly to zero about one window
                // after the last landing. The windowed rate is already a sustained figure, so the session
                // peak takes its maximum directly and needs no short-gap laundering guard.
                trailOut = advanceTokenTrail(priorState.tokenTrail, current: current, previous: previous)
                smoothed = windowedTokenRate(trail: trailOut, at: current.timestamp)
                peakSmoothed = 0
                peak = max(priorPeak, smoothed)
            } else {
                // Live rate: the clamped snapshot delta over elapsed time, smoothed by the EMA. The clamp
                // absorbs counter noise and the midnight totals reset (a negative delta reads as zero); a
                // zero or missing elapsed holds the last smoothed value rather than dividing by zero.
                let priorSmoothed = priorState.smoothedRate[kind] ?? 0
                // A session peak may only capture honest live readings: deltas measured over short gaps.
                // The display EMA still averages a long gap (the warm background carry, a wake from sleep)
                // into a truthful recent rate, but peaks come from a SEPARATE peak-only EMA that integrates
                // exclusively short-gap measurements and resets whenever a long gap breaks the chain —
                // otherwise the long-gap average would carry in the display EMA and the next short tick
                // could promote its residue to a peak no short window ever measured.
                peakSmoothed = priorState.peakSmoothed[kind] ?? 0
                if let previous, current.timestamp.timeIntervalSince(previous.timestamp) > 0 {
                    let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
                    let d = max(0, delta(current: current, previous: previous, kinds: kind.rateKinds))
                    let perUnit = kind.isPerSecond ? elapsed : elapsed / 60.0
                    let raw = Double(d) / perUnit
                    smoothed = emaAlpha * raw + (1 - emaAlpha) * priorSmoothed
                    peakSmoothed = elapsed <= peakMaxElapsed
                        ? emaAlpha * raw + (1 - emaAlpha) * peakSmoothed
                        : 0
                } else {
                    smoothed = priorSmoothed
                }
                // The EMA only asymptotes toward zero; snap it once it falls well under the liveness
                // threshold so an idle channel actually reads zero instead of decaying forever. (The
                // windowed COGNITION rate reaches exact zero on its own and needs no snap.)
                if smoothed < kind.livenessThreshold * 0.25 { smoothed = 0 }
                peak = max(priorPeak, peakSmoothed)
            }
            smoothedOut[kind] = smoothed
            peakOut[kind] = peak
            peakSmoothedOut[kind] = peakSmoothed
            let peakPosition = peak > 0 ? min(1.0, peak / denominator) : nil

            channels.append(MeterChannel(
                kind: kind, availability: availability, uncalibratedTag: tag,
                needsPermission: needsPermission, bars: bars, rawBars: rawBars,
                isLive: smoothed >= kind.livenessThreshold,
                tokenSplit: kind == .cognition
                    ? TokenSplit(payable: current.totals[.aiInputTokens] ?? 0,
                                 receivable: current.totals[.aiOutputTokens] ?? 0)
                    : nil,
                subline: subline(kind: kind, totals: current.totals, exposureFraction: 0,
                                 mechanicsPeak: peak),
                rate: smoothed, rateReadout: readout(kind: kind, rate: smoothed),
                peak: peak, peakReadout: readout(kind: kind, rate: peak), peakPosition: peakPosition,
                exposureFraction: 0, exposureReadout: ""
            ))
        }

        return MeterBridge(channels: channels,
                           state: MeterState(smoothedRate: smoothedOut, peakRate: peakOut,
                                             peakSmoothed: peakSmoothedOut, tokenTrail: trailOut))
    }

    // MARK: - Internals

    /// Sums the requested kinds' minute series into one per-minute array of the given length, treating a
    /// missing or short series as zeros so ragged input never traps.
    private static func combine(series: [MetricKind: [Int64]], kinds: [MetricKind], length: Int) -> [Int64] {
        guard length > 0 else { return [] }
        var out = [Int64](repeating: 0, count: length)
        for kind in kinds {
            guard let arr = series[kind] else { continue }
            for i in 0..<min(length, arr.count) { out[i] += arr[i] }
        }
        return out
    }

    /// Aggregates a per-minute series into the window's buckets and converts each bucket to the channel's
    /// rate axis, so floors, normalization, and the peak mark all share one scale regardless of the
    /// window's zoom. The most recent `window.totalMinutes` minutes are taken (zero-padded at the front
    /// when history is shorter, so a short history's signal lands in the newest buckets), summed into
    /// `window.bucketCount` buckets of `window.bucketMinutes`, then divided onto the rate axis:
    /// per-second channels by the bucket's seconds (bytes/s), per-minute channels by its minutes
    /// (tokens/min, keys/min). EXPOSURE takes the per-minute path too, and since its floor is one full
    /// attentive minute, its bar reads attentive seconds per bucket over the bucket's capacity — an
    /// absolute fraction that never inflates against a busy window.
    private static func rateAxisBuckets(minutes: [Int64], kind: MeterChannelKind, window: MeterWindow) -> [Double] {
        let total = window.totalMinutes
        let recent: [Int64]
        if minutes.count >= total {
            recent = Array(minutes.suffix(total))
        } else {
            recent = [Int64](repeating: 0, count: total - minutes.count) + minutes
        }
        var buckets = [Int64](repeating: 0, count: window.bucketCount)
        for (i, value) in recent.enumerated() { buckets[i / window.bucketMinutes] += value }
        let divisor = kind.isPerSecond ? Double(window.bucketMinutes * 60) : Double(window.bucketMinutes)
        return buckets.map { Double($0) / divisor }
    }

    /// Advances COGNITION's trail with the current reading and trims it to the trailing window. The trim
    /// keeps the newest point at or beyond the window boundary as the measurement anchor, so the windowed
    /// delta spans at least the full window once enough history exists. An empty trail seeds from
    /// `previous`, so a caller that never carried state still measures against its previous reading.
    private static func advanceTokenTrail(
        _ trail: [TokenTrailPoint], current: MeterSnapshot, previous: MeterSnapshot?
    ) -> [TokenTrailPoint] {
        func tokens(_ snapshot: MeterSnapshot) -> Int64 {
            (snapshot.totals[.aiInputTokens] ?? 0) + (snapshot.totals[.aiOutputTokens] ?? 0)
        }
        var out = trail
        if out.isEmpty, let previous, previous.timestamp < current.timestamp {
            out = [TokenTrailPoint(timestamp: previous.timestamp, total: tokens(previous))]
        }
        // A total below the trail's newest reading is the midnight counter reset: the old points measure
        // a counter that no longer exists, so the trail restarts at the new reading.
        if let last = out.last, tokens(current) < last.total { out = [] }
        // Append only a strictly newer instant; a same-instant rebuild re-reads the standing trail.
        if out.last.map({ $0.timestamp < current.timestamp }) ?? true {
            out.append(TokenTrailPoint(timestamp: current.timestamp, total: tokens(current)))
        }
        let cutoff = current.timestamp.addingTimeInterval(-cognitionWindowSeconds)
        while out.count >= 2, out[1].timestamp <= cutoff { out.removeFirst() }
        return out
    }

    /// Tokens landed over the trailing window, in tok/min: the newest trail total against the anchor (the
    /// trail's oldest point). Dividing by at least the full window keeps a young trail honest — a burst
    /// right after a cold start reads a sustained figure, never an instantaneous spike. An anchor older
    /// than the window (the 30-second background cadence can leave it up to one tick beyond the boundary)
    /// divides by its true span instead, an equally honest recent average.
    private static func windowedTokenRate(trail: [TokenTrailPoint], at now: Date) -> Double {
        guard let anchor = trail.first, let newest = trail.last else { return 0 }
        let landed = Double(max(0, newest.total - anchor.total))
        let span = now.timeIntervalSince(anchor.timestamp)
        return landed / (max(span, cognitionWindowSeconds) / 60.0)
    }

    /// Sums the snapshot delta of the requested kinds between two readings.
    private static func delta(current: MeterSnapshot, previous: MeterSnapshot, kinds: [MetricKind]) -> Int64 {
        var d: Int64 = 0
        for kind in kinds { d += (current.totals[kind] ?? 0) - (previous.totals[kind] ?? 0) }
        return d
    }

    /// Normalizes the rate-axis bucket values to 0-1 against the window maximum, floored so an idle window
    /// stays flat. The values already live on the channel's rate axis (see `rateAxisBuckets`), which is
    /// the same axis the peak mark and the per-channel floor live on, so the bars and the peak position
    /// share one scale. Returns the bars and the denominator (the current full-scale) for placing the peak.
    private static func normalize(rateValues: [Double], floor: Double) -> (bars: [Double], denominator: Double) {
        let windowMax = rateValues.max() ?? 0
        let denominator = max(windowMax, floor)
        let bars = rateValues.map { min(1.0, max(0.0, $0 / denominator)) }
        return (bars, denominator)
    }

    /// Maps availability to the engraved tag and the permission affordance flag. A `regrant` channel in
    /// the needs-permission state engraves the stale-grant tag instead of the generic UNCALIBRATED.
    private static func calibration(kind: MeterChannelKind, availability: Availability, regrant: Bool) -> (tag: String?, needsPermission: Bool) {
        switch availability {
        case .running:
            return (nil, false)
        case .needsPermission:
            return (regrant ? regrantTag : uncalibratedTag, true)
        case .sourceMissing:
            return (kind == .cognition ? cognitionUncalibratedTag : uncalibratedTag, false)
        case .disabled:
            return (uncalibratedTag, false)
        }
    }

    /// The formatted rate readout in the channel's unit.
    private static func readout(kind: MeterChannelKind, rate: Double) -> String {
        switch kind {
        case .traffic, .storage: return ByteFormatting.byteRate(rate)
        case .cognition: return ByteFormatting.tokenRate(rate)
        case .mechanics: return ByteFormatting.keyRate(rate)
        case .exposure: return ""
        }
    }

    /// Today's directional totals sub-line for the channel. MECHANICS additionally carries the day's
    /// click count and its live cadence peak (`mechanicsPeak`, the session peak-hold in keys/min), so the
    /// keyboard-and-mouse channel reads "keys · clicks · peak kpm · distance".
    private static func subline(kind: MeterChannelKind, totals: [MetricKind: Int64],
                                exposureFraction: Double, mechanicsPeak: Double = 0) -> String {
        func t(_ k: MetricKind) -> Int64 { totals[k] ?? 0 }
        switch kind {
        case .traffic:
            return "down \(ByteFormatting.bytes(t(.networkBytesIn))) / up \(ByteFormatting.bytes(t(.networkBytesOut)))"
        case .storage:
            return "read \(ByteFormatting.bytes(t(.diskBytesRead))) / write \(ByteFormatting.bytes(t(.diskBytesWritten)))"
        case .cognition:
            return "in \(ByteFormatting.tokens(t(.aiInputTokens))) / out \(ByteFormatting.tokens(t(.aiOutputTokens))) tok"
        case .mechanics:
            return "\(ByteFormatting.grouped(t(.inputKeystrokes))) keys · "
                + "\(ByteFormatting.grouped(t(.inputClicks))) clicks · "
                + "peak \(ByteFormatting.keyRate(mechanicsPeak)) · "
                + "\(ByteFormatting.distanceHauled(milliPixels: t(.inputMouseMilliPixels)))"
        case .exposure:
            return String(format: "%.1f%% of 24h", exposureFraction * 100)
        }
    }
}
