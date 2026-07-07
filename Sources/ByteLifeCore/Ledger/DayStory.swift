import Foundation

/// One account's card on the day dashboard. It carries the channel-colored 24 hourly amounts combined
/// across the account's kinds, the day-total headline formatted in the account's own unit, and the
/// compact figure rows in ledger columns (reusing `DaySheetLine`'s debit/credit/memo semantics). Pure
/// and deterministic, so the whole dashboard is covered by `swift test`.
public struct DayStoryCard: Equatable, Sendable, Identifiable {
    public let kind: LedgerAccountKind
    /// The account's combined amount per hour, one Int64 for each hour 0..<24.
    public let hourly: [Int64]
    /// The day total, formatted in the account's unit (tokens compact, bytes, HH:MM, or grouped keys).
    public let headline: String
    /// The compact figure rows, in the same debit/credit/memo shape the live day sheet prints.
    public let lines: [DaySheetLine]

    public var title: String { kind.title }
    public var id: String { kind.rawValue }

    public init(kind: LedgerAccountKind, hourly: [Int64], headline: String, lines: [DaySheetLine]) {
        self.kind = kind
        self.hourly = hourly
        self.headline = headline
        self.lines = lines
    }
}

/// The whole day dashboard shaped from one day's totals and its 24-hour series: the five account cards
/// in canonical order (Token, Traffic, Storage, Hours, Labor), the day's posted byte volume for the
/// header hero figure, and the Traffic and Storage hourly arrays exposed separately for the hero flow
/// chart. Built purely over `Ledger`, `DaySheet`, and `ByteFormatting`, so no figure logic is duplicated
/// and the model is fully covered by `swift test`.
public struct DayStory: Equatable, Sendable {
    public let dayEpoch: Int64
    /// The five account cards in canonical order.
    public let cards: [DayStoryCard]
    /// The day's posted byte volume (Traffic and Storage churn), formatted for the header hero figure.
    public let postedByteVolume: String
    /// The Traffic account's 24 hourly amounts (in + out), for the hero flow chart's teal area.
    public let trafficHourly: [Int64]
    /// The Storage account's 24 hourly amounts (read + written), for the hero flow chart's violet area.
    public let storageHourly: [Int64]

    public init(
        dayEpoch: Int64,
        cards: [DayStoryCard],
        postedByteVolume: String,
        trafficHourly: [Int64],
        storageHourly: [Int64]
    ) {
        self.dayEpoch = dayEpoch
        self.cards = cards
        self.postedByteVolume = postedByteVolume
        self.trafficHourly = trafficHourly
        self.storageHourly = storageHourly
    }

    /// The metric kinds the dashboard's hourly bars need, so the window queries exactly these in one
    /// `SampleStore.hourlySeries` call. Cache tokens and mouse travel are figure-only and stay out.
    public static let hourlyKinds: [MetricKind] = LedgerAccountKind.allCases.flatMap(kinds(for:))

    /// Builds the story from the day's totals and its per-kind 24-hour series. Kinds absent from either
    /// input read as zero, so an empty day yields a structurally complete, all-zero story. A `cadence`
    /// supplied for a single day adds the day's typing rhythm to the Labor card as two memo lines;
    /// aggregate periods pass none, so cadence is a day-granularity figure only.
    public static func build(
        dayEpoch: Int64,
        totals: [MetricKind: Int64],
        hourly: [MetricKind: [Int64]],
        cadence: TypingCadence? = nil
    ) -> DayStory {
        let ledger = Ledger(totals: totals)
        // Reuse the live day sheet's line logic verbatim; a historical read has no availability badges.
        let sheet = DaySheet.build(totals: totals, availabilityByFamily: [:], reconciliation: nil)
        let linesByKind = Dictionary(uniqueKeysWithValues: sheet.accounts.map { ($0.kind, $0.lines) })

        let cards = LedgerAccountKind.allCases.map { kind -> DayStoryCard in
            let account = ledger.account(kind)
            var lines = linesByKind[kind] ?? []
            // The Hours card adds a percent-of-day memo the compact live sheet does not print.
            if kind == .hours {
                lines.append(DaySheetLine(label: "Percent of day",
                                          value: percentOfDay(seconds: account.debit), side: .memo))
            }
            // The Labor card carries the day's typing rhythm as two memo lines when a cadence is supplied.
            if kind == .labor, let cadence {
                lines.append(contentsOf: cadenceLines(cadence))
            }
            return DayStoryCard(
                kind: kind,
                hourly: combined(kinds(for: kind), hourly),
                // Every account's headline is its churn: debit + credit for the paired accounts, the
                // lone debit for the expense accounts, formatted in the account's own unit.
                headline: headline(for: kind, total: account.churn),
                lines: lines
            )
        }

        return DayStory(
            dayEpoch: dayEpoch,
            cards: cards,
            postedByteVolume: ByteFormatting.bytes(ledger.runningBalance),
            trafficHourly: combined(kinds(for: .traffic), hourly),
            storageHourly: combined(kinds(for: .storage), hourly)
        )
    }

    /// The kinds whose hourly series an account combines into its bars. Internal so `PeriodStory` sums
    /// the same channels per day, keeping one definition of which metrics each account owns.
    static func kinds(for kind: LedgerAccountKind) -> [MetricKind] {
        switch kind {
        case .token: return [.aiInputTokens, .aiOutputTokens]
        case .traffic: return [.networkBytesIn, .networkBytesOut]
        case .storage: return [.diskBytesRead, .diskBytesWritten]
        case .hours: return [.screenAttentiveSeconds]
        case .labor: return [.inputKeystrokes]
        }
    }

    /// Sums the given kinds' hourly arrays element-wise into a fresh 24-slot array, treating a missing
    /// kind or a short array as zeros.
    private static func combined(_ kinds: [MetricKind], _ hourly: [MetricKind: [Int64]]) -> [Int64] {
        var result = [Int64](repeating: 0, count: 24)
        for kind in kinds {
            guard let series = hourly[kind] else { continue }
            for hour in 0..<Swift.min(24, series.count) {
                result[hour] += series[hour]
            }
        }
        return result
    }

    /// The day-total headline in the account's own unit. Internal so `PeriodStory` formats an aggregate
    /// total through the very same rule (tokens compact, bytes, HH:MM, or grouped keys).
    static func headline(for kind: LedgerAccountKind, total: Int64) -> String {
        switch kind {
        case .token: return ByteFormatting.tokens(total)
        case .traffic, .storage: return ByteFormatting.bytes(total)
        case .hours: return ByteFormatting.hoursMinutes(seconds: total)
        case .labor: return ByteFormatting.grouped(total)
        }
    }

    /// Attentive seconds as a percentage of a 24-hour day, one decimal, e.g. 24120 -> "27.9%".
    private static func percentOfDay(seconds: Int64) -> String {
        String(format: "%.1f%%", Double(max(0, seconds)) / 864.0)
    }

    /// The typing-rhythm memo lines for the Labor card: the busiest minute's keystrokes and the mean over
    /// active minutes, both in keys per minute. Pure, so the shaping is covered by `swift test`.
    static func cadenceLines(_ cadence: TypingCadence) -> [DaySheetLine] {
        [
            DaySheetLine(label: "Peak cadence", value: "\(cadence.peakKeysPerMinute) kpm", side: .memo),
            DaySheetLine(label: "Avg cadence",
                         value: "\(Int(cadence.averageKeysPerActiveMinute.rounded())) kpm", side: .memo),
        ]
    }
}
