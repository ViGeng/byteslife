import Foundation

/// The posting state of one accounting period in the General Ledger's center column: either closed
/// with a stored stamp, or still open. Derived from whether a reconciliation row exists for the day.
public enum PeriodState: Equatable, Sendable {
    /// The day is closed; the payload is the stored stamp ("BALANCED" or "FLAGGED").
    case posted(stamp: String)
    /// The day holds samples but has not been reconciled yet.
    case unposted

    public var isPosted: Bool {
        if case .posted = self { return true }
        return false
    }
}

/// One recorded day as the General Ledger lists it: its epoch, a locale-independent date and weekday
/// label, and its posting state. Pure and deterministic, built from a day epoch and the day's optional
/// reconciliation stamp, so the window's center column is fully covered by `swift test`.
public struct LedgerPeriod: Equatable, Sendable, Identifiable {
    public let dayEpoch: Int64
    /// ISO-style `YYYY-MM-DD`, rendered from the day epoch with the same calendar the receipt uses.
    public let dateLabel: String
    /// Fixed three-letter English weekday ("Mon"), computed by hand so it never depends on locale.
    public let weekday: String
    public let state: PeriodState

    public var isPosted: Bool { state.isPosted }
    public var id: Int64 { dayEpoch }

    public init(dayEpoch: Int64, dateLabel: String, weekday: String, state: PeriodState) {
        self.dayEpoch = dayEpoch
        self.dateLabel = dateLabel
        self.weekday = weekday
        self.state = state
    }

    /// Fixed short weekday names indexed by `Calendar`'s 1-based weekday component (1 = Sunday).
    private static let shortWeekdays = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Builds the newest-first list of periods from the days that hold samples and the map of closed
    /// days to their stamp. The two sets are unioned so a posted day still lists even in the unlikely
    /// case its samples were pruned, and days sort strictly newest-first.
    public static func list(
        daysWithData: [Int64],
        stampsByDay: [Int64: String],
        calendar: Calendar = .current
    ) -> [LedgerPeriod] {
        let allDays = Set(daysWithData).union(stampsByDay.keys)
        return allDays.sorted(by: >).map { day in
            let date = Date(timeIntervalSince1970: TimeInterval(day))
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let dateLabel = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let weekdayIndex = c.weekday ?? 0
            let weekday = shortWeekdays.indices.contains(weekdayIndex) ? shortWeekdays[weekdayIndex] : ""
            let state: PeriodState = stampsByDay[day].map { .posted(stamp: $0) } ?? .unposted
            return LedgerPeriod(dayEpoch: day, dateLabel: dateLabel, weekday: weekday, state: state)
        }
    }
}

/// One row of the all-history trial balance shown in the window's right rail: an account (or a labor
/// sub-line) with its debit and credit columns already formatted in the account's own unit. Expense
/// accounts carry an empty credit, which the ledger books honestly rather than faking a balancing side.
public struct TrialBalanceRow: Equatable, Sendable, Identifiable {
    /// The account title, or the indented label of a sub-line under it.
    public let label: String
    /// The formatted debit figure, unit-correct for the account.
    public let debit: String
    /// The formatted credit figure, or "" for an expense account with no credit side.
    public let credit: String
    /// True for the second Labor line (distance hauled), so the view can indent it under its account.
    public let isSubline: Bool

    public var id: String { label }

    public init(label: String, debit: String, credit: String, isSubline: Bool) {
        self.label = label
        self.debit = debit
        self.credit = credit
        self.isSubline = isSubline
    }
}

/// Builds the trial balance rows from an all-history totals dictionary. Pure formatting over a
/// `Ledger`, so the right rail's figures come from the same rollup and formatters the receipt uses.
public enum TrialBalance {
    /// One row per account in canonical order, plus a Labor distance sub-line, each column formatted in
    /// the account's natural unit (tokens and keys grouped, byte accounts in binary units, hours in
    /// HH:MM, mouse travel in meters or kilometers).
    public static func rows(totals: [MetricKind: Int64]) -> [TrialBalanceRow] {
        let ledger = Ledger(totals: totals)
        let token = ledger.account(.token)
        let traffic = ledger.account(.traffic)
        let storage = ledger.account(.storage)
        let hours = ledger.account(.hours)
        let labor = ledger.account(.labor)
        return [
            TrialBalanceRow(
                label: LedgerAccountKind.token.title,
                debit: ByteFormatting.grouped(token.debit),
                credit: ByteFormatting.grouped(token.credit),
                isSubline: false
            ),
            TrialBalanceRow(
                label: LedgerAccountKind.traffic.title,
                debit: ByteFormatting.bytes(traffic.debit),
                credit: ByteFormatting.bytes(traffic.credit),
                isSubline: false
            ),
            TrialBalanceRow(
                label: LedgerAccountKind.storage.title,
                debit: ByteFormatting.bytes(storage.debit),
                credit: ByteFormatting.bytes(storage.credit),
                isSubline: false
            ),
            TrialBalanceRow(
                label: LedgerAccountKind.hours.title,
                debit: ByteFormatting.hoursMinutes(seconds: hours.debit),
                credit: "",
                isSubline: false
            ),
            TrialBalanceRow(
                label: LedgerAccountKind.labor.title,
                debit: ByteFormatting.grouped(labor.debit),
                credit: "",
                isSubline: false
            ),
            TrialBalanceRow(
                label: "Distance Hauled",
                debit: ByteFormatting.distanceHauled(milliPixels: ledger.mouseMilliPixels),
                credit: "",
                isSubline: true
            ),
        ]
    }
}
