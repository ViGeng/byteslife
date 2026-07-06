import Foundation

/// Maps a wall-clock timestamp to ByteLife's storage coordinates. The write path and the read
/// path both go through this helper, so they can never disagree on where a sample lands.
///
/// `dayEpoch` is the Unix time (seconds) of local-calendar midnight for the timestamp; `minute`
/// is the minute-of-day. Day boundaries are naive local midnight per PLAN.md accepted risks:
/// there is no special timezone or DST handling.
public struct DayBucket: Equatable {
    public let dayEpoch: Int64
    public let minute: Int32

    public init(dayEpoch: Int64, minute: Int32) {
        self.dayEpoch = dayEpoch
        self.minute = minute
    }

    /// Buckets `date` using `calendar`, which defaults to the current local calendar.
    public init(date: Date, calendar: Calendar = .current) {
        let startOfDay = calendar.startOfDay(for: date)
        dayEpoch = Int64(startOfDay.timeIntervalSince1970.rounded(.down))
        let secondsIntoDay = date.timeIntervalSince(startOfDay)
        minute = Int32((secondsIntoDay / 60).rounded(.down))
    }

    /// The local-midnight day epoch for `date`, matching the write path exactly.
    public static func dayEpoch(for date: Date, calendar: Calendar = .current) -> Int64 {
        DayBucket(date: date, calendar: calendar).dayEpoch
    }
}
