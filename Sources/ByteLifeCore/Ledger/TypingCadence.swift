import Foundation

/// The typing rhythm of a day, derived purely from the keystroke minute buckets already recorded. No
/// new collection: the Labor Account's `inputKeystrokes` cells are summed a second way to describe how
/// hard the day's typing ran rather than how much of it there was.
///
/// An *active minute* is any minute that carried at least one keystroke. The peak is the busiest single
/// minute; the average is over active minutes only, so long idle stretches never dilute the figure into
/// meaninglessness. Both are zero for a day with no typing. Pure and deterministic: no clock, no I/O.
public struct TypingCadence: Equatable, Sendable {
    /// Keystrokes in the busiest single minute of the day.
    public let peakKeysPerMinute: Int64
    /// Mean keystrokes across the minutes that carried any typing. Zero when there were none.
    public let averageKeysPerActiveMinute: Double
    /// How many minutes carried at least one keystroke.
    public let activeMinutes: Int

    public init(peakKeysPerMinute: Int64, averageKeysPerActiveMinute: Double, activeMinutes: Int) {
        self.peakKeysPerMinute = peakKeysPerMinute
        self.averageKeysPerActiveMinute = averageKeysPerActiveMinute
        self.activeMinutes = activeMinutes
    }

    /// Derives the cadence from a day's per-minute keystroke counts. Zero-typing minutes are ignored for
    /// the average but still allowed as gaps; the array need not be a full 1,440-minute day.
    public static func from(minuteKeystrokes buckets: [Int64]) -> TypingCadence {
        let active = buckets.filter { $0 > 0 }
        let peak = buckets.max() ?? 0
        guard !active.isEmpty else {
            return TypingCadence(peakKeysPerMinute: peak, averageKeysPerActiveMinute: 0, activeMinutes: 0)
        }
        let total = active.reduce(Int64(0), +)
        return TypingCadence(
            peakKeysPerMinute: peak,
            averageKeysPerActiveMinute: Double(total) / Double(active.count),
            activeMinutes: active.count
        )
    }
}
