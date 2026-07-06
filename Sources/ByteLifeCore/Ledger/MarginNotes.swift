import Foundation

/// Which margin rule produced a note. Exposed so callers and tests can assert selection without
/// pattern-matching on the sentence text.
public enum MarginRule: String, Sendable, CaseIterable {
    case variance
    case generatedExceedsTyped
    case largestAccount
    case quietDay
    case fallback
}

/// One margin comment: the rule that fired and its dry bookkeeper sentence.
public struct MarginNote: Equatable, Sendable {
    public let rule: MarginRule
    public let text: String

    public init(rule: MarginRule, text: String) {
        self.rule = rule
        self.text = text
    }
}

/// The deterministic local rule engine that writes the receipt's single margin comment. It compares
/// today against the trailing recorded days and returns exactly one dry, judgment-free sentence in
/// the bookkeeper's flat register. Rules are tried in a fixed priority order and the first whose
/// guard passes wins; every internal choice (which series varied most, which account was largest)
/// breaks ties by a fixed order, so identical inputs always yield the identical note. No AI, no clock.
public enum MarginNotes {
    /// A series must move at least this many percent off its trailing average to be remarkable.
    static let varianceThresholdPercent = 100

    /// A day is "quiet" only when it falls below all three of these floors together.
    static let quietByteVolume: Int64 = 200 * 1024 * 1024
    static let quietTokenVolume: Int64 = 500
    static let quietKeystrokes: Int64 = 300

    /// Named series compared for variance, in fixed priority order for deterministic tie-breaking.
    private struct Series {
        let name: String
        let value: (Ledger) -> Int64
    }

    private static let series: [Series] = [
        Series(name: "Network traffic") { $0.account(.traffic).churn },
        Series(name: "Storage volume") { $0.account(.storage).churn },
        Series(name: "Token volume") { $0.account(.token).churn },
        Series(name: "Keys struck") { $0.account(.labor).debit },
        Series(name: "Screen time") { $0.account(.hours).debit },
    ]

    /// The winning note for `today` given up to seven trailing recorded days.
    public static func note(today: [MetricKind: Int64], trailing: [[MetricKind: Int64]]) -> MarginNote {
        let ledger = Ledger(totals: today)
        let trailingLedgers = trailing.map { Ledger(totals: $0) }

        if let n = varianceNote(ledger, trailingLedgers) { return n }
        if let n = generatedExceedsTypedNote(ledger) { return n }
        if let n = largestAccountNote(ledger) { return n }
        if let n = quietDayNote(ledger) { return n }
        return MarginNote(
            rule: .fallback,
            text: "Books balanced against the day. Nothing stands out. Filed as usual."
        )
    }

    /// Convenience returning only the sentence.
    public static func comment(today: [MetricKind: Int64], trailing: [[MetricKind: Int64]]) -> String {
        note(today: today, trailing: trailing).text
    }

    // MARK: - Rules

    private static func varianceNote(_ today: Ledger, _ trailing: [Ledger]) -> MarginNote? {
        guard !trailing.isEmpty else { return nil }
        var best: (name: String, pct: Int)?
        for s in series {
            let average = Double(trailing.reduce(0) { $0 + s.value($1) }) / Double(trailing.count)
            guard average > 0 else { continue }
            let pct = Int((((Double(s.value(today)) - average) / average) * 100).rounded())
            guard abs(pct) >= varianceThresholdPercent else { continue }
            // Strictly greater keeps the earlier series on a tie, so selection is order-stable.
            if best == nil || abs(pct) > abs(best!.pct) {
                best = (s.name, pct)
            }
        }
        guard let best else { return nil }
        let direction = best.pct >= 0 ? "up" : "down"
        return MarginNote(
            rule: .variance,
            text: "\(best.name) \(direction) \(abs(best.pct))% versus the trailing average. No judgment. Filing it."
        )
    }

    private static func generatedExceedsTypedNote(_ today: Ledger) -> MarginNote? {
        let generated = today.account(.token).credit
        let struck = today.account(.labor).debit
        guard generated > 0, struck > 0, generated > struck else { return nil }
        return MarginNote(
            rule: .generatedExceedsTyped,
            text: "Tokens receivable outran keys struck, \(ByteFormatting.grouped(generated)) to "
                + "\(ByteFormatting.grouped(struck)). Booking the surplus to the machine."
        )
    }

    private static func largestAccountNote(_ today: Ledger) -> MarginNote? {
        let traffic = today.account(.traffic).churn
        let storage = today.account(.storage).churn
        let (kind, churn) = storage > traffic
            ? (LedgerAccountKind.storage, storage)
            : (LedgerAccountKind.traffic, traffic)
        guard churn >= quietByteVolume else { return nil }
        return MarginNote(
            rule: .largestAccount,
            text: "\(kind.title) carried the day at \(ByteFormatting.bytes(churn)) posted. Entered without comment."
        )
    }

    private static func quietDayNote(_ today: Ledger) -> MarginNote? {
        guard today.runningBalance < quietByteVolume,
              today.account(.token).churn < quietTokenVolume,
              today.account(.labor).debit < quietKeystrokes else { return nil }
        return MarginNote(
            rule: .quietDay,
            text: "Quiet books. Little posted today. The ledger keeps its own counsel."
        )
    }
}
