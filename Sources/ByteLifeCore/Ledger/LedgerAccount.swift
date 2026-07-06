import Foundation

/// The five ledger accounts of the Double-Entry Self, one per `MetricFamily`. Raw string values are
/// stable and used as dictionary keys; the human titles are the concept sheet's exact account names.
public enum LedgerAccountKind: String, CaseIterable, Sendable {
    case token
    case traffic
    case storage
    case hours
    case labor

    /// The exact account name printed on the receipt and shown in the General Ledger.
    public var title: String {
        switch self {
        case .token: return "Token Account"
        case .traffic: return "Traffic Account"
        case .storage: return "Storage Account"
        case .hours: return "Hours Under the Lamp"
        case .labor: return "Labor Account"
        }
    }

    public var family: MetricFamily {
        switch self {
        case .token: return .ai
        case .traffic: return .network
        case .storage: return .disk
        case .hours: return .screen
        case .labor: return .input
        }
    }

    /// The account a collector family posts to. One-to-one with `family`, so a short collector maps
    /// cleanly onto the account named in a FLAGGED receipt.
    public init(family: MetricFamily) {
        switch family {
        case .ai: self = .token
        case .network: self = .traffic
        case .disk: self = .storage
        case .screen: self = .hours
        case .input: self = .labor
        }
    }
}

/// One posted account with its two ledger columns. The bookkeeping rule is that what flows out of
/// you posts as a debit and what comes back posts as a credit. The two expense accounts (`hours`,
/// `labor`) carry no credit side, which the ledger books honestly rather than forcing to balance.
public struct LedgerAccount: Equatable, Sendable {
    public let kind: LedgerAccountKind
    /// The debit column: tokens prompted, bytes remitted, bytes written, seconds of attention, or
    /// keystrokes struck, depending on the account.
    public let debit: Int64
    /// The credit column: tokens generated, bytes received, or bytes read. Zero for expense accounts.
    public let credit: Int64

    public init(kind: LedgerAccountKind, debit: Int64, credit: Int64) {
        self.kind = kind
        self.debit = debit
        self.credit = credit
    }

    /// Credit minus debit: positive when more came back than went out. Meaningful only for the three
    /// paired accounts; the expense accounts report it as a formality.
    public var net: Int64 { credit - debit }

    /// Total posted volume through both columns, the "churn" figure the ledger reports for the byte
    /// accounts and uses to rank the day's largest mover.
    public var churn: Int64 { debit + credit }
}

/// A day rolled up into the five accounts. Built once from a `[MetricKind: Int64]` totals dictionary
/// (kinds absent from the day read as zero) and then queried for the figures the receipt, the margin
/// engine, and the menubar need. Pure and deterministic: no locale, no clock, no I/O.
public struct Ledger: Equatable, Sendable {
    public let totals: [MetricKind: Int64]

    public init(totals: [MetricKind: Int64]) {
        self.totals = totals
    }

    private func total(_ kind: MetricKind) -> Int64 { totals[kind] ?? 0 }

    /// The account for `kind`, with its debit and credit columns resolved from the day's totals.
    public func account(_ kind: LedgerAccountKind) -> LedgerAccount {
        switch kind {
        case .token:
            return LedgerAccount(kind: kind, debit: total(.aiInputTokens), credit: total(.aiOutputTokens))
        case .traffic:
            return LedgerAccount(kind: kind, debit: total(.networkBytesOut), credit: total(.networkBytesIn))
        case .storage:
            return LedgerAccount(kind: kind, debit: total(.diskBytesWritten), credit: total(.diskBytesRead))
        case .hours:
            return LedgerAccount(kind: kind, debit: total(.screenAttentiveSeconds), credit: 0)
        case .labor:
            return LedgerAccount(kind: kind, debit: total(.inputKeystrokes), credit: 0)
        }
    }

    /// All five accounts in their canonical order (Token, Traffic, Storage, Hours, Labor).
    public var accounts: [LedgerAccount] { LedgerAccountKind.allCases.map(account) }

    // MARK: - Token Account extras

    /// Cache-creation tokens, kept off the payable line so cache traffic never distorts the exchange
    /// rate. Reported only as a memo figure.
    public var cacheCreationTokens: Int64 { total(.aiCacheCreationTokens) }

    /// Cache-read tokens, reported alongside cache-creation on the same memo line.
    public var cacheReadTokens: Int64 { total(.aiCacheReadTokens) }

    /// The generated-to-prompted ratio (credit over debit) printed as the exchange-rate footnote.
    /// `nil` when nothing was prompted, because the ratio is then undefined rather than zero.
    public var tokenExchangeRate: Double? {
        let prompted = total(.aiInputTokens)
        guard prompted > 0 else { return nil }
        return Double(total(.aiOutputTokens)) / Double(prompted)
    }

    // MARK: - Labor Account extras

    /// Raw mouse travel in milli-pixels, the Labor Account's second debit sub-line before conversion.
    public var mouseMilliPixels: Int64 { total(.inputMouseMilliPixels) }

    /// Mouse travel converted to meters at the assumed pixel density.
    public var metersHauled: Double { ByteFormatting.meters(milliPixels: mouseMilliPixels) }

    // MARK: - Running balance

    /// The menubar's headline: the day's posted byte volume, defined as every debit and credit of the
    /// two byte accounts (Traffic and Storage). Tokens, hours, and labor keep their own units and are
    /// never folded into this figure.
    public var runningBalance: Int64 {
        account(.traffic).churn + account(.storage).churn
    }
}
