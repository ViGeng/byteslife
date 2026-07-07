import Foundation

/// One day in the dashboard sidebar's activity list: the day's tokens and posted byte volume, plus each
/// figure normalized against the largest day in the list so the two thin minis under the date read as a
/// history chart. Pure and deterministic. This is the single source of truth for a day's posted byte
/// volume series, subsuming the old per-day posted-volume helper.
public struct DayActivityRow: Equatable, Sendable, Identifiable {
    public let dayEpoch: Int64
    /// Tokens moved that day: AI input plus output (the Token Account's churn).
    public let tokens: Int64
    /// Posted byte volume that day: every Traffic and Storage debit and credit (the running balance).
    public let bytes: Int64
    /// `tokens` divided by the largest token day in the list, in 0...1; zero when every day is zero.
    public let tokenFraction: Double
    /// `bytes` divided by the largest byte day in the list, in 0...1; zero when every day is zero.
    public let byteFraction: Double

    public var id: Int64 { dayEpoch }

    public init(dayEpoch: Int64, tokens: Int64, bytes: Int64,
                tokenFraction: Double, byteFraction: Double) {
        self.dayEpoch = dayEpoch
        self.tokens = tokens
        self.bytes = bytes
        self.tokenFraction = tokenFraction
        self.byteFraction = byteFraction
    }
}

/// Builds the sidebar's per-day activity list, newest first, from the recorded days and the multi-day
/// totals the ledger already queries. Both token and byte figures come from `Ledger`, so the dashboard
/// reads a day's tokens and posted byte volume from one rollup rather than a parallel computation.
public enum DayActivity {
    /// One row per day, newest first. Each figure is normalized against the maximum across the listed
    /// days, so the minis share a scale; when a maximum is zero every fraction on that axis is zero.
    /// Days present in `daysWithData` but absent from `totalsByDay` read as an all-zero day.
    public static func rows(
        daysWithData: [Int64],
        totalsByDay: [Int64: [MetricKind: Int64]]
    ) -> [DayActivityRow] {
        let raw = daysWithData.sorted(by: >).map { day -> (day: Int64, tokens: Int64, bytes: Int64) in
            let ledger = Ledger(totals: totalsByDay[day] ?? [:])
            return (day, ledger.account(.token).churn, ledger.runningBalance)
        }
        let maxTokens = raw.map(\.tokens).max() ?? 0
        let maxBytes = raw.map(\.bytes).max() ?? 0
        return raw.map { entry in
            DayActivityRow(
                dayEpoch: entry.day,
                tokens: entry.tokens,
                bytes: entry.bytes,
                tokenFraction: maxTokens > 0 ? Double(entry.tokens) / Double(maxTokens) : 0,
                byteFraction: maxBytes > 0 ? Double(entry.bytes) / Double(maxBytes) : 0
            )
        }
    }
}
