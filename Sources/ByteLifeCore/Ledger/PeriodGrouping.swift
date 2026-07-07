import Foundation

/// The granularity of the Back Office's period sidebar: a single day, an ISO-8601 week (Monday start),
/// or a local-calendar month. Raw values are stable and drive the segmented picker's persisted choice.
public enum PeriodGranularity: String, CaseIterable, Sendable {
    case day
    case week
    case month

    /// The segmented picker's label.
    public var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// True for the two aggregate granularities, whose sidebar rows show posted coverage rather than a
    /// single day's stamp and whose main pane shows the aggregate period story.
    public var isAggregate: Bool { self != .day }
}

/// One period in the sidebar list: its member day epochs newest-first, a granularity-appropriate label,
/// and the period's aggregate token and byte figures with each normalized across the listed periods so
/// the two activity minis under the label read as a history chart. The token and byte definitions come
/// from `Ledger` (a day's token churn and posted byte volume), exactly as `DayActivity` defines them, so
/// a day, a week, and a month all sum the same underlying figures. Pure and deterministic.
public struct PeriodGroup: Equatable, Sendable, Identifiable {
    public let granularity: PeriodGranularity
    /// The member days that fell in this period, newest first. Always at least one, since periods form
    /// only from recorded days.
    public let dayEpochs: [Int64]
    /// The rendered label: a day's "Jul 7", a week's "Week 28 · Jul 6–12", or a month's "July 2026".
    public let label: String
    /// Tokens moved across the period: each member day's Token Account churn (input + output), summed.
    public let tokens: Int64
    /// Posted byte volume across the period: each member day's Traffic and Storage churn, summed.
    public let bytes: Int64
    /// `tokens` over the largest period's tokens in the list, in 0...1; zero when every period is zero.
    public let tokenFraction: Double
    /// `bytes` over the largest period's bytes in the list, in 0...1; zero when every period is zero.
    public let byteFraction: Double
    /// How many member days have been reconciled, for the "posted / total" coverage chip.
    public let postedCount: Int

    /// The number of member days, the denominator of the coverage chip.
    public var dayCount: Int { dayEpochs.count }
    /// True once every member day is posted, so the coverage chip may take the brass tint.
    public var fullyPosted: Bool { dayCount > 0 && postedCount == dayCount }
    /// The newest member epoch, unique per period because periods never overlap, so it is a stable id and
    /// selection key.
    public var id: Int64 { dayEpochs.first ?? 0 }

    public init(granularity: PeriodGranularity, dayEpochs: [Int64], label: String,
                tokens: Int64, bytes: Int64, tokenFraction: Double, byteFraction: Double,
                postedCount: Int) {
        self.granularity = granularity
        self.dayEpochs = dayEpochs
        self.label = label
        self.tokens = tokens
        self.bytes = bytes
        self.tokenFraction = tokenFraction
        self.byteFraction = byteFraction
        self.postedCount = postedCount
    }
}

/// Groups recorded day epochs into periods at a chosen granularity for the Back Office sidebar. Weeks
/// follow ISO-8601 (Monday start, week 1 is the week holding the year's first Thursday); months follow
/// the local calendar. Pure and deterministic: every calendar decision resolves through the passed
/// calendar (the current one by default), so `swift test` fixes both boundaries and labels against a
/// fixed time zone.
public enum PeriodGrouping {
    /// The periods for `granularity`, newest first, each carrying its member days, label, aggregate token
    /// and byte totals, and posted coverage. Token and byte figures are normalized across the listed
    /// periods (the `DayActivity` approach): each figure divides by the largest period in the list, and a
    /// zero maximum yields a zero fraction. Days absent from `totalsByDay` count as all-zero days.
    public static func groups(
        daysWithData: [Int64],
        granularity: PeriodGranularity,
        totalsByDay: [Int64: [MetricKind: Int64]],
        stampsByDay: [Int64: String] = [:],
        calendar: Calendar = .current
    ) -> [PeriodGroup] {
        let iso = isoCalendar(calendar)

        // Bucket the recorded days by their period key.
        var buckets: [Int64: [Int64]] = [:]
        for day in daysWithData {
            buckets[key(for: day, granularity: granularity, calendar: calendar, iso: iso), default: []]
                .append(day)
        }

        // One raw entry per period, its members newest-first, with the aggregate figures summed from the
        // same `Ledger` definitions `DayActivity` uses for a single day.
        struct Raw { let members: [Int64]; let tokens: Int64; let bytes: Int64; let posted: Int }
        var raws: [Raw] = buckets.values.map { days in
            let members = days.sorted(by: >)
            var tokens: Int64 = 0
            var bytes: Int64 = 0
            var posted = 0
            for day in members {
                let ledger = Ledger(totals: totalsByDay[day] ?? [:])
                tokens += ledger.account(.token).churn
                bytes += ledger.runningBalance
                if stampsByDay[day] != nil { posted += 1 }
            }
            return Raw(members: members, tokens: tokens, bytes: bytes, posted: posted)
        }
        // Newest first by newest member; disjoint periods make this a total order.
        raws.sort { ($0.members.first ?? 0) > ($1.members.first ?? 0) }

        let maxTokens = raws.map(\.tokens).max() ?? 0
        let maxBytes = raws.map(\.bytes).max() ?? 0
        return raws.map { raw in
            PeriodGroup(
                granularity: granularity,
                dayEpochs: raw.members,
                label: label(for: raw.members.first ?? 0, granularity: granularity,
                             calendar: calendar, iso: iso),
                tokens: raw.tokens,
                bytes: raw.bytes,
                tokenFraction: maxTokens > 0 ? Double(raw.tokens) / Double(maxTokens) : 0,
                byteFraction: maxBytes > 0 ? Double(raw.bytes) / Double(maxBytes) : 0,
                postedCount: raw.posted
            )
        }
    }

    /// An ISO-8601 calendar in the given calendar's time zone: Monday start, first week holds the year's
    /// first Thursday. Used for week keys and week labels so both agree on the boundary.
    static func isoCalendar(_ calendar: Calendar) -> Calendar {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso
    }

    /// The bucket key that collapses days in the same period to one group: the day epoch itself for a
    /// day, the epoch of the week's Monday for a week, and the epoch of the month's first day for a month.
    /// Each key is monotonic in time, so sorting keys descending sorts periods newest-first.
    private static func key(for day: Int64, granularity: PeriodGranularity,
                            calendar: Calendar, iso: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(day))
        switch granularity {
        case .day:
            return day
        case .week:
            let start = iso.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            return Int64(start.timeIntervalSince1970)
        case .month:
            let c = calendar.dateComponents([.year, .month], from: date)
            let first = calendar.date(from: DateComponents(year: c.year, month: c.month, day: 1)) ?? date
            return Int64(first.timeIntervalSince1970)
        }
    }

    /// The label for a period, computed from any of its member days.
    private static func label(for day: Int64, granularity: PeriodGranularity,
                              calendar: Calendar, iso: Calendar) -> String {
        switch granularity {
        case .day:
            return DayLabel.short(dayEpoch: day, calendar: calendar)
        case .week:
            return weekLabel(for: day, iso: iso)
        case .month:
            return DayLabel.monthYear(dayEpoch: day, calendar: calendar)
        }
    }

    /// "Week 28 · Jul 6–12": the ISO week number zero-padded to two digits, a middle-dot, and the week's
    /// Monday-to-Sunday span with locale-independent month abbreviations (an en-dash between the days, and
    /// a second month shown only when the week straddles a month boundary).
    private static func weekLabel(for day: Int64, iso: Calendar) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(day))
        let week = iso.component(.weekOfYear, from: date)
        let monday = iso.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let sunday = iso.date(byAdding: .day, value: 6, to: monday) ?? monday
        let m = iso.dateComponents([.month, .day], from: monday)
        let s = iso.dateComponents([.month, .day], from: sunday)
        let span: String
        if m.month == s.month {
            span = "\(DayLabel.abbreviatedMonth(m.month ?? 0)) \(m.day ?? 0)–\(s.day ?? 0)"
        } else {
            span = "\(DayLabel.abbreviatedMonth(m.month ?? 0)) \(m.day ?? 0)"
                + "–\(DayLabel.abbreviatedMonth(s.month ?? 0)) \(s.day ?? 0)"
        }
        return String(format: "Week %02d · %@", week, span)
    }
}
