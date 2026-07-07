import Foundation

/// Locale-independent day labels for the Back Office dashboard: the sidebar rows want a short "Jul 7"
/// and the day header wants the full "Tuesday, July 7, 2026". Both are computed by hand from a day epoch
/// so they never depend on the user's locale or a `DateFormatter`, mirroring `LedgerPeriod`'s calendar
/// handling (the epoch resolves through the given calendar, the current one by default, exactly as the
/// write path buckets a day). Pure and deterministic, so `swift test` covers both formats.
public enum DayLabel {
    private static let fullMonths = ["", "January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]
    private static let shortMonths = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let fullWeekdays = ["", "Sunday", "Monday", "Tuesday", "Wednesday",
                                       "Thursday", "Friday", "Saturday"]

    /// "Jul 7": abbreviated month and day of month, for the sidebar period rows.
    public static func short(dayEpoch: Int64, calendar: Calendar = .current) -> String {
        let c = components(dayEpoch, calendar)
        return "\(name(shortMonths, c.month)) \(c.day ?? 0)"
    }

    /// "Tuesday, July 7, 2026": full weekday, month, day, and year, for the day header.
    public static func full(dayEpoch: Int64, calendar: Calendar = .current) -> String {
        let c = components(dayEpoch, calendar)
        return "\(name(fullWeekdays, c.weekday)), \(name(fullMonths, c.month)) \(c.day ?? 0), \(c.year ?? 0)"
    }

    private static func components(_ dayEpoch: Int64, _ calendar: Calendar) -> DateComponents {
        let date = Date(timeIntervalSince1970: TimeInterval(dayEpoch))
        return calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    }

    /// A name from a 1-based table, empty when the index is missing or out of range.
    private static func name(_ table: [String], _ index: Int?) -> String {
        guard let index, table.indices.contains(index) else { return "" }
        return table[index]
    }
}
