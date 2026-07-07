import Foundation

/// A selectable history window for a Meter Bridge chart: how far back it reaches and how coarsely it
/// buckets that reach. The four tokens span a live half hour up to a full day, each landing on a
/// comfortable bar count (30, 30, 36, 48) so the sparkline stays legible at every zoom. `totalMinutes`
/// and `bucketMinutes` are the only knobs; the bucket count and the rate-axis conversion derive from
/// them, so a chart at any window still normalizes against the same floors and holds its peak on one
/// scale.
public enum MeterWindow: String, CaseIterable, Sendable {
    /// 30 one-minute buckets: the live half hour.
    case w30m
    /// 30 two-minute buckets: the last hour.
    case h1
    /// 36 ten-minute buckets: the last six hours.
    case h6
    /// 48 thirty-minute buckets: the last day.
    case h24

    /// Minutes of history the window spans.
    public var totalMinutes: Int {
        switch self {
        case .w30m: return 30
        case .h1: return 60
        case .h6: return 360
        case .h24: return 1440
        }
    }

    /// Minutes summed into each bucket.
    public var bucketMinutes: Int {
        switch self {
        case .w30m: return 1
        case .h1: return 2
        case .h6: return 10
        case .h24: return 30
        }
    }

    /// The number of buckets the chart renders: `totalMinutes / bucketMinutes` (30, 30, 36, 48).
    public var bucketCount: Int { totalMinutes / bucketMinutes }

    /// The compact token engraved in the window menu.
    public var token: String {
        switch self {
        case .w30m: return "30M"
        case .h1: return "1H"
        case .h6: return "6H"
        case .h24: return "24H"
        }
    }

    /// The window every chart opens at: the live half hour, one bucket per minute.
    public static let `default`: MeterWindow = .w30m
}
