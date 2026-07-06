import Foundation

/// Which ledger column a figure posts to, so the panel can colour it: debits in oxblood, credits in
/// ledger-green, and derived memo figures in plain ink. The two expense accounts emit only debit lines,
/// so a credit is never faked to make them balance.
public enum LedgerSide: Sendable, Equatable {
    case debit
    case credit
    case memo
}

/// One printed line inside an account block: a label, its formatted figure, and the column it posts to.
public struct DaySheetLine: Equatable, Sendable, Identifiable {
    public let label: String
    public let value: String
    public let side: LedgerSide
    public var id: String { label }

    public init(label: String, value: String, side: LedgerSide) {
        self.label = label
        self.value = value
        self.side = side
    }
}

/// One account block on the live day sheet: its account kind (which carries the exact title), its posted
/// lines in reading order, the collector's current availability, and an optional in-character disclosure
/// when the account is not fully open.
public struct DaySheetAccount: Equatable, Sendable, Identifiable {
    public let kind: LedgerAccountKind
    public let lines: [DaySheetLine]
    public let availability: Availability
    /// The disclosure shown under the account when it is not fully open. A missing AI source reads as
    /// "account not yet opened"; a running Token Account still discloses that only Claude Code reports.
    /// It is `nil` for a needs-permission account, because the panel offers the request-permission
    /// affordance in that case instead of a passive line.
    public let disclosure: String?

    public var title: String { kind.title }
    public var id: String { kind.rawValue }

    public init(kind: LedgerAccountKind, lines: [DaySheetLine], availability: Availability, disclosure: String?) {
        self.kind = kind
        self.lines = lines
        self.availability = availability
        self.disclosure = disclosure
    }
}

/// The compact live day sheet the menubar dropdown renders: the five accounts with their current debit
/// and credit lines, the day's running balance, and whether the day has been reconciled. Built purely
/// from a totals dictionary, an availability map, and today's reconciliation row, so it is fully covered
/// by `swift test` with no clock, locale, or I/O of its own.
public struct DaySheet: Equatable, Sendable {
    public let accounts: [DaySheetAccount]
    /// The day's posted byte volume (Traffic and Storage churn), formatted, shown as the running balance.
    public let postedByteVolume: String
    /// True once the day has been reconciled; the panel then disables Reconcile and shows the stamp.
    public let isPosted: Bool
    /// The stored stamp ("BALANCED" or "FLAGGED") when posted, else `nil`.
    public let stamp: String?

    public init(accounts: [DaySheetAccount], postedByteVolume: String, isPosted: Bool, stamp: String?) {
        self.accounts = accounts
        self.postedByteVolume = postedByteVolume
        self.isPosted = isPosted
        self.stamp = stamp
    }

    /// The disclosure a source-missing account shows: an unopened book rather than a broken feature.
    public static let notYetOpened = "Account not yet opened."

    /// The Token Account's standing disclosure in v1, where only Claude Code's local logs report and
    /// every other AI tool is honestly an account not yet opened.
    public static let partialTokenSources = "Partial: Claude Code reporting. Other tools not yet opened."

    /// Builds the day sheet from the day's totals, each family's availability, and today's reconciliation
    /// (nil when the day is still open).
    public static func build(
        totals: [MetricKind: Int64],
        availabilityByFamily: [MetricFamily: Availability],
        reconciliation: Reconciliation?
    ) -> DaySheet {
        let ledger = Ledger(totals: totals)

        let accounts = LedgerAccountKind.allCases.map { kind -> DaySheetAccount in
            let availability = availabilityByFamily[kind.family] ?? .disabled
            return DaySheetAccount(
                kind: kind,
                lines: lines(for: kind, ledger: ledger),
                availability: availability,
                disclosure: disclosure(for: kind, availability: availability)
            )
        }

        return DaySheet(
            accounts: accounts,
            postedByteVolume: ByteFormatting.bytes(ledger.runningBalance),
            isPosted: reconciliation != nil,
            stamp: reconciliation?.stamp
        )
    }

    private static func lines(for kind: LedgerAccountKind, ledger: Ledger) -> [DaySheetLine] {
        let account = ledger.account(kind)
        switch kind {
        case .token:
            var lines = [
                DaySheetLine(label: "Tokens Payable", value: ByteFormatting.grouped(account.debit), side: .debit),
                DaySheetLine(label: "Tokens Receivable", value: ByteFormatting.grouped(account.credit), side: .credit),
            ]
            let rate = ledger.tokenExchangeRate.map { String(format: "%.2f : 1", $0) } ?? "n/a"
            lines.append(DaySheetLine(label: "Exchange rate", value: rate, side: .memo))
            if ledger.cacheCreationTokens > 0 || ledger.cacheReadTokens > 0 {
                let memo = "\(ByteFormatting.tokens(ledger.cacheCreationTokens)) w / \(ByteFormatting.tokens(ledger.cacheReadTokens)) r"
                lines.append(DaySheetLine(label: "Cache", value: memo, side: .memo))
            }
            return lines
        case .traffic:
            let netSide = account.net >= 0 ? "Cr" : "Dr"
            return [
                DaySheetLine(label: "Bytes Remitted", value: ByteFormatting.bytes(account.debit), side: .debit),
                DaySheetLine(label: "Bytes Received", value: ByteFormatting.bytes(account.credit), side: .credit),
                DaySheetLine(label: "Net flow", value: "\(netSide) \(ByteFormatting.bytes(abs(account.net)))", side: .memo),
            ]
        case .storage:
            return [
                DaySheetLine(label: "Writes Posted", value: ByteFormatting.bytes(account.debit), side: .debit),
                DaySheetLine(label: "Reads Drawn", value: ByteFormatting.bytes(account.credit), side: .credit),
                DaySheetLine(label: "Churn", value: ByteFormatting.bytes(account.churn), side: .memo),
            ]
        case .hours:
            // An expense account: a single debit line accruing in HH:MM, never a faked credit.
            return [
                DaySheetLine(label: "Attention", value: ByteFormatting.hoursMinutes(seconds: account.debit), side: .debit),
            ]
        case .labor:
            // Two expense sub-lines under one account, both debits with no credit side.
            return [
                DaySheetLine(label: "Keys Struck", value: ByteFormatting.grouped(account.debit), side: .debit),
                DaySheetLine(label: "Distance Hauled", value: ByteFormatting.distanceHauled(milliPixels: ledger.mouseMilliPixels), side: .debit),
            ]
        }
    }

    private static func disclosure(for kind: LedgerAccountKind, availability: Availability) -> String? {
        switch availability {
        case .running:
            // The Token Account is always partial in v1 even when reporting, so it discloses that.
            return kind == .token ? partialTokenSources : nil
        case .sourceMissing:
            return notYetOpened
        case .needsPermission:
            // The panel renders the request-permission affordance; no passive disclosure line here.
            return nil
        case .disabled:
            return nil
        }
    }
}
