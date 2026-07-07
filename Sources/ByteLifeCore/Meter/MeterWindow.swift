import Foundation

/// A selectable history window for a Meter Bridge chart: how far back it reaches and how coarsely it
/// buckets that reach. The four fixed tokens span a live half hour up to a full day, each landing on a
/// comfortable bar count (30, 30, 36, 48) so the sparkline stays legible at every zoom. The fifth,
/// `custom`, is the user-defined WORK window: one duration from an hour up to two days, configured once
/// and offered in every menu. `totalMinutes` and `bucketMinutes` are the only knobs; the bucket count and
/// the rate-axis conversion derive from them, so a chart at any window still normalizes against the same
/// floors and holds its peak on one scale.
///
/// The type is `RawRepresentable` over `String` (not a raw-value enum, since `custom` carries minutes) so
/// it persists through `@AppStorage` exactly as the fixed cases did; `allCases` lists only the four fixed
/// windows, because the WORK window is one live global value rather than a fixed member.
public enum MeterWindow: Sendable, Equatable, Hashable {
    /// 30 one-minute buckets: the live half hour.
    case w30m
    /// 30 two-minute buckets: the last hour.
    case h1
    /// 36 ten-minute buckets: the last six hours.
    case h6
    /// 48 thirty-minute buckets: the last day.
    case h24
    /// The user-defined WORK window carrying its span in minutes, clamped to [60, 2880] (1 to 48 hours).
    case custom(minutes: Int)

    /// The lower and upper bounds of a WORK window's span, in minutes: one hour up to two days.
    public static let customMinRange = 60
    public static let customMaxRange = 2880

    /// Minutes of history the window spans. A custom span is clamped to the supported 1-to-48-hour range.
    public var totalMinutes: Int {
        switch self {
        case .w30m: return 30
        case .h1: return 60
        case .h6: return 360
        case .h24: return 1440
        case .custom(let minutes):
            return min(Self.customMaxRange, max(Self.customMinRange, minutes))
        }
    }

    /// Minutes summed into each bucket. A custom window derives a divisor-friendly bucket size that keeps
    /// its bar count between 30 and 48 (see `deriveBucketMinutes`).
    public var bucketMinutes: Int {
        switch self {
        case .w30m: return 1
        case .h1: return 2
        case .h6: return 10
        case .h24: return 30
        case .custom:
            return Self.deriveBucketMinutes(totalMinutes: totalMinutes)
        }
    }

    /// The number of buckets the chart renders: `totalMinutes / bucketMinutes` (30, 30, 36, 48 for the
    /// fixed windows, and 30 to 48 for a custom window). Uses ceiling division so a bucket size that does
    /// not divide the span evenly can never under-count buckets and index past the array.
    public var bucketCount: Int { (totalMinutes + bucketMinutes - 1) / bucketMinutes }

    /// The compact token engraved in the window menu.
    public var token: String {
        switch self {
        case .w30m: return "30M"
        case .h1: return "1H"
        case .h6: return "6H"
        case .h24: return "24H"
        case .custom: return "WORK"
        }
    }

    /// Whether this is the user-defined WORK window.
    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The window every chart opens at: the live half hour, one bucket per minute.
    public static let `default`: MeterWindow = .w30m

    /// The fixed windows offered in every menu, in order, and the entirety of `allCases`. The WORK window
    /// is appended by the UI from the live global duration, so it is deliberately absent here.
    public static let fixedCases: [MeterWindow] = [.w30m, .h1, .h6, .h24]

    /// Derives a bucket size for a custom span that keeps the rendered bar count between 30 and 48.
    ///
    /// The span in minutes divided by 48 is the smallest bucket size that stays at or under 48 bars; the
    /// span divided by 30 is the largest that stays at or above 30. We round the lower bound UP to the
    /// first divisor-friendly value in that band, preferring one that divides the span evenly so no bar
    /// covers a partial bucket. WORK spans are always whole hours (a multiple of 60), so an even divisor
    /// always exists; for a hypothetical non-multiple span the search still returns the first candidate in
    /// the band, and the ceiling `bucketCount` keeps rendering safe.
    public static func deriveBucketMinutes(totalMinutes: Int) -> Int {
        let span = min(customMaxRange, max(customMinRange, totalMinutes))
        let lower = Int((Double(span) / 48.0).rounded(.up))
        let upper = max(lower, span / 30)
        // Prefer a bucket size that divides the span evenly, scanning up from the lower bound.
        for candidate in lower...upper where span % candidate == 0 {
            return candidate
        }
        // No even divisor in the band (only reachable for a non-multiple-of-60 span): take the lower
        // bound, which still bounds the bar count at 48; ceiling division absorbs the remainder.
        return lower
    }
}

extension MeterWindow: CaseIterable {
    /// Only the fixed windows are enumerable members; the WORK window is a live global value.
    public static var allCases: [MeterWindow] { fixedCases }
}

extension MeterWindow: RawRepresentable {
    /// Reconstructs a window from its persisted token. The fixed windows use their bare case names (as the
    /// former raw-value enum did, so existing `@AppStorage` values keep resolving); a WORK window persists
    /// as `work:<minutes>`.
    public init?(rawValue: String) {
        switch rawValue {
        case "w30m": self = .w30m
        case "h1": self = .h1
        case "h6": self = .h6
        case "h24": self = .h24
        default:
            guard rawValue.hasPrefix("work:"), let minutes = Int(rawValue.dropFirst(5)) else { return nil }
            self = .custom(minutes: minutes)
        }
    }

    public var rawValue: String {
        switch self {
        case .w30m: return "w30m"
        case .h1: return "h1"
        case .h6: return "h6"
        case .h24: return "h24"
        case .custom(let minutes): return "work:\(minutes)"
        }
    }
}
