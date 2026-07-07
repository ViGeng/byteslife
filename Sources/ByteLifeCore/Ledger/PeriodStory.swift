import Foundation

/// One member day of an aggregate period, for the posted-coverage chips at the foot of the period story:
/// its epoch, its day-of-month (the aggregate charts' x-axis unit), and its posting state. Clicking a
/// chip jumps the Back Office to that day in Day granularity.
public struct PeriodDay: Equatable, Sendable, Identifiable {
    public let dayEpoch: Int64
    /// Day of month, e.g. 6 for July 6, used as the per-day bar chart's axis label.
    public let dayOfMonth: Int
    public let state: PeriodState

    public var isPosted: Bool { state.isPosted }
    public var id: Int64 { dayEpoch }

    public init(dayEpoch: Int64, dayOfMonth: Int, state: PeriodState) {
        self.dayEpoch = dayEpoch
        self.dayOfMonth = dayOfMonth
        self.state = state
    }
}

/// One account's card on the aggregate period dashboard: the same shape as `DayStoryCard`, but its bar
/// series is one value per member day (not per hour) and its headline and figure rows are the account's
/// totals summed across the period. The figure logic is reused from `DaySheet`, `DayStory.headline`, and
/// `DayStory.kinds`, so nothing about what an account means is redefined here.
public struct PeriodStoryCard: Equatable, Sendable, Identifiable {
    public let kind: LedgerAccountKind
    /// The account's combined amount per member day, aligned to `PeriodStory.days` (oldest first).
    public let perDay: [Int64]
    /// The period total, formatted in the account's unit.
    public let headline: String
    /// The compact figure rows in the same debit/credit/memo shape a single day prints, over the sums.
    public let lines: [DaySheetLine]

    public var title: String { kind.title }
    public var id: String { kind.rawValue }

    public init(kind: LedgerAccountKind, perDay: [Int64], headline: String, lines: [DaySheetLine]) {
        self.kind = kind
        self.perDay = perDay
        self.headline = headline
        self.lines = lines
    }
}

/// The aggregate story shown when a week or month is selected: the period label, its member days with
/// posting state, the five account cards summed across the period with per-day bar series, the aggregate
/// posted byte volume for the header hero figure, the Traffic and Storage per-day arrays for the hero bar
/// chart, and the posted-coverage figures. Built purely from the per-day totals already in memory (no
/// hourly fetch), reusing `Ledger`, `DaySheet`, and `DayStory`'s figure helpers so no account math is
/// duplicated, and fully covered by `swift test`.
public struct PeriodStory: Equatable, Sendable {
    public let label: String
    /// Member days oldest-first, so the aggregate charts read left-to-right in time.
    public let days: [PeriodDay]
    /// The five account cards in canonical order (Token, Traffic, Storage, Hours, Labor).
    public let cards: [PeriodStoryCard]
    /// The period's posted byte volume (Traffic + Storage churn over all members), formatted.
    public let postedByteVolume: String
    /// How many member days are reconciled.
    public let postedCount: Int
    /// The Traffic account's per-day amounts, for the hero bar chart's teal bars.
    public let trafficPerDay: [Int64]
    /// The Storage account's per-day amounts, for the hero bar chart's violet bars.
    public let storagePerDay: [Int64]

    /// The total number of member days.
    public var dayCount: Int { days.count }
    /// True once every member day is posted.
    public var fullyPosted: Bool { dayCount > 0 && postedCount == dayCount }
    /// "3 of 7 days posted", the coverage line that replaces the receipt on an aggregate period.
    public var coverageText: String { "\(postedCount) of \(dayCount) days posted" }

    public init(label: String, days: [PeriodDay], cards: [PeriodStoryCard],
                postedByteVolume: String, postedCount: Int,
                trafficPerDay: [Int64], storagePerDay: [Int64]) {
        self.label = label
        self.days = days
        self.cards = cards
        self.postedByteVolume = postedByteVolume
        self.postedCount = postedCount
        self.trafficPerDay = trafficPerDay
        self.storagePerDay = storagePerDay
    }

    /// Builds the story for a period from its member days and the per-day totals map. `dayEpochs` may be
    /// in any order; the story orders its days and per-day series oldest-first. Kinds and days absent from
    /// `totalsByDay` read as zero, so a structurally complete story always results.
    public static func build(
        label: String,
        dayEpochs: [Int64],
        totalsByDay: [Int64: [MetricKind: Int64]],
        stampsByDay: [Int64: String] = [:],
        calendar: Calendar = .current
    ) -> PeriodStory {
        let ordered = dayEpochs.sorted()

        // The aggregate totals: every member day's per-kind figures summed into one dictionary, then read
        // through `Ledger` and `DaySheet` exactly as a single day is.
        var summed: [MetricKind: Int64] = [:]
        for day in ordered {
            for (kind, value) in totalsByDay[day] ?? [:] { summed[kind, default: 0] += value }
        }
        let ledger = Ledger(totals: summed)
        // Reuse the live day sheet's line logic verbatim over the sums; an aggregate read has no badges.
        let sheet = DaySheet.build(totals: summed, availabilityByFamily: [:], reconciliation: nil)
        let linesByKind = Dictionary(uniqueKeysWithValues: sheet.accounts.map { ($0.kind, $0.lines) })

        let days = ordered.map { day -> PeriodDay in
            let c = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: TimeInterval(day)))
            let state: PeriodState = stampsByDay[day].map { .posted(stamp: $0) } ?? .unposted
            return PeriodDay(dayEpoch: day, dayOfMonth: c.day ?? 0, state: state)
        }

        let cards = LedgerAccountKind.allCases.map { kind -> PeriodStoryCard in
            let kinds = DayStory.kinds(for: kind)
            let perDay = ordered.map { day in
                kinds.reduce(Int64(0)) { $0 + (totalsByDay[day]?[$1] ?? 0) }
            }
            return PeriodStoryCard(
                kind: kind,
                perDay: perDay,
                headline: DayStory.headline(for: kind, total: ledger.account(kind).churn),
                lines: linesByKind[kind] ?? []
            )
        }

        return PeriodStory(
            label: label,
            days: days,
            cards: cards,
            postedByteVolume: ByteFormatting.bytes(ledger.runningBalance),
            postedCount: ordered.reduce(0) { $0 + (stampsByDay[$1] != nil ? 1 : 0) },
            trafficPerDay: cards.first { $0.kind == .traffic }?.perDay ?? [],
            storagePerDay: cards.first { $0.kind == .storage }?.perDay ?? []
        )
    }
}
