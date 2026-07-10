import Foundation

/// One component series of the BYTELIFE COMPOSITE. Each component is a sum of metric kinds that share a
/// unit, so a component can be compared against its own history even though components can never be
/// added to each other.
public enum CompositeComponent: String, CaseIterable, Sendable {
    /// Bytes moved: network traffic plus disk storage flow.
    case bytesMoved
    /// Tokens prompted and generated. Cache tokens stay excluded, per the ledger's exchange-rate reasoning.
    case tokens
    /// Attentive seconds at the screen.
    case attention
    /// Input events: keystrokes plus clicks plus scroll units.
    case inputEvents

    /// The short lowercase name disclosures print, e.g. "tokens excluded (zero baseline)".
    public var displayName: String {
        switch self {
        case .bytesMoved: return "bytes"
        case .tokens: return "tokens"
        case .attention: return "attention"
        case .inputEvents: return "input"
        }
    }

    /// The metric kinds summed into this component's daily value.
    var kinds: [MetricKind] {
        switch self {
        case .bytesMoved: return [.networkBytesIn, .networkBytesOut, .diskBytesRead, .diskBytesWritten]
        case .tokens: return [.aiInputTokens, .aiOutputTokens]
        case .attention: return [.screenAttentiveSeconds]
        case .inputEvents: return [.inputKeystrokes, .inputClicks, .inputScrollUnits]
        }
    }

    /// The component's value on one day: its kinds summed, with an absent kind counting zero (a recorded
    /// day that booked nothing on a kind genuinely had none of it).
    func value(in totals: [MetricKind: Int64]) -> Int64 {
        kinds.reduce(0) { $0 + (totals[$1] ?? 0) }
    }
}

/// One component's day-over-baseline comparison inside an indexed Composite.
public struct CompositeRatio: Equatable, Sendable {
    public let component: CompositeComponent
    /// The target day's value for this component.
    public let today: Int64
    /// The median of the component over the trailing recorded baseline days. Always positive here; a
    /// zero-baseline component drops out of the reading instead of carrying a ratio.
    public let baseline: Double
    /// today / baseline, clamped to [0.05, 20] so a single wild day cannot dominate the index.
    public let ratio: Double

    public init(component: CompositeComponent, today: Int64, baseline: Double, ratio: Double) {
        self.component = component
        self.today = today
        self.baseline = baseline
        self.ratio = ratio
    }
}

/// The numbers behind an indexed Composite: the display-rounded index, the ratios that entered the
/// geometric mean, and the components that dropped out for having a zero baseline.
public struct CompositeReading: Equatable, Sendable {
    /// The index rounded for display: 100 is a typical day, 132 is a third busier than typical.
    public let index: Int
    /// The components that entered the mean, in fixed `CompositeComponent.allCases` order.
    public let ratios: [CompositeRatio]
    /// The zero-baseline components excluded from the mean, disclosed rather than silently zeroed.
    public let dropped: [CompositeComponent]

    public init(index: Int, ratios: [CompositeRatio], dropped: [CompositeComponent]) {
        self.index = index
        self.ratios = ratios
        self.dropped = dropped
    }
}

/// The BYTELIFE COMPOSITE: a market-style index over four component series, each compared against the
/// median of its own trailing history, combined as a geometric mean of unit-free ratios times 100 so no
/// unit can outweigh another. Pure and clock-free: shaped entirely from the target day's totals and a
/// history map (the shape `SampleStore.totals(forDayEpochs:)` returns), so every state is covered by
/// `swift test` with no store.
public enum Composite: Equatable, Sendable {
    /// Fewer than `minimumBaselineDays` recorded days precede the target day, so there is no honest
    /// baseline yet. Carries how many recorded days exist so far.
    case collecting(recordedDays: Int)
    /// Enough recorded days exist but every component's baseline median is zero, so no ratio has meaning.
    /// Distinct from `collecting` because the history is real; the machine simply booked nothing.
    case noBaseline
    /// The index computed from at least one component with a positive baseline.
    case indexed(CompositeReading)

    /// The baseline spans the trailing 28 recorded days strictly before the target day. Recorded means
    /// present in the history map; calendar gaps do not count against the window.
    public static let baselineWindow = 28
    /// Fewer recorded baseline days than this yields `collecting` instead of a fake number.
    public static let minimumBaselineDays = 5
    /// Clamp bounds on each component's day-over-baseline ratio.
    public static let ratioFloor = 0.05
    public static let ratioCeiling = 20.0

    /// Builds the day's Composite from the target `dayEpoch`, that day's metric totals, and the history
    /// map keyed by dayEpoch. Days at or after the target day are ignored even if present in the map, so
    /// the target day can never inflate its own baseline.
    public static func build(
        dayEpoch: Int64,
        todayTotals: [MetricKind: Int64],
        history: [Int64: [MetricKind: Int64]]
    ) -> Composite {
        let baselineDays = history.keys.filter { $0 < dayEpoch }.sorted(by: >).prefix(baselineWindow)
        guard baselineDays.count >= minimumBaselineDays else {
            return .collecting(recordedDays: baselineDays.count)
        }

        var ratios: [CompositeRatio] = []
        var dropped: [CompositeComponent] = []
        for component in CompositeComponent.allCases {
            let baseline = median(baselineDays.map { component.value(in: history[$0] ?? [:]) })
            guard baseline > 0 else {
                // A zero baseline gives no honest denominator, whether today moved or not: the component
                // drops out and is disclosed instead of fabricating a clamped ratio.
                dropped.append(component)
                continue
            }
            let today = component.value(in: todayTotals)
            let ratio = min(max(Double(today) / baseline, ratioFloor), ratioCeiling)
            ratios.append(CompositeRatio(component: component, today: today, baseline: baseline, ratio: ratio))
        }
        guard !ratios.isEmpty else { return .noBaseline }

        let meanLog = ratios.reduce(0.0) { $0 + log($1.ratio) } / Double(ratios.count)
        let index = Int((100.0 * exp(meanLog)).rounded())
        return .indexed(CompositeReading(index: index, ratios: ratios, dropped: dropped))
    }

    /// The median of the series: the middle value for an odd count, the mean of the two middle values for
    /// an even count. The caller guarantees a non-empty series.
    static func median(_ values: [Int64]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[mid]) }
        return (Double(sorted[mid - 1]) + Double(sorted[mid])) / 2
    }

    // MARK: Display strings

    /// The engraved label of the panel-header chip.
    public static let chipLabel = "COMPOSITE"

    /// The chip figure: the rounded index, or the dim dash while there is nothing honest to print (the
    /// chip renders dim in both non-indexed states).
    public var chipValue: String {
        switch self {
        case .indexed(let reading): return String(reading.index)
        case .collecting, .noBaseline: return "—"
        }
    }

    /// The receipt totals-block fragment, e.g. "Composite vs 28-day median: 132".
    public var receiptLine: String {
        let prefix = "Composite vs \(Self.baselineWindow)-day median"
        switch self {
        case .indexed(let reading):
            return "\(prefix): \(reading.index)"
        case .collecting(let recordedDays):
            return "\(prefix): collecting baseline (\(recordedDays) of \(Self.minimumBaselineDays) days)"
        case .noBaseline:
            return "\(prefix): no baseline"
        }
    }

    /// The dropped-component disclosure, e.g. "tokens excluded (zero baseline)", or nil when every
    /// component entered the mean.
    public var disclosure: String? {
        switch self {
        case .indexed(let reading):
            guard !reading.dropped.isEmpty else { return nil }
            let names = reading.dropped.map(\.displayName).joined(separator: ", ")
            return "\(names) excluded (zero baseline)"
        case .noBaseline:
            return "all components excluded (zero baseline)"
        case .collecting:
            return nil
        }
    }
}
