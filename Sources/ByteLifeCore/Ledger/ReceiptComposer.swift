import Foundation
import CryptoKit

/// The stamp a reconciled day carries. `balanced` when every collector was running at close;
/// `flagged` when one or more dropped out, naming the short accounts so the gap is disclosed;
/// `postedInArrears` when a past day is closed after the fact, because collector availability for
/// the period was not retained and the receipt discloses the late posting rather than fabricating
/// BALANCED or naming spuriously short accounts from today's state.
public enum ReceiptStamp: Equatable, Sendable {
    case balanced
    case flagged(shortAccounts: [String])
    case postedInArrears

    /// The value stored in the `reconciliations.stamp` column.
    public var storageValue: String {
        switch self {
        case .balanced: return "BALANCED"
        case .flagged: return "FLAGGED"
        case .postedInArrears: return "POSTED IN ARREARS"
        }
    }
}

/// A composed receipt: the immutable fixed-width text, the stamp it printed, and the content hash
/// (16 hex characters) taken over the canonical body. Composed once at reconciliation, stored
/// verbatim, and re-rendered from storage ever after.
public struct Receipt: Equatable, Sendable {
    public let text: String
    public let stamp: ReceiptStamp
    public let contentHash: String

    public init(text: String, stamp: ReceiptStamp, contentHash: String) {
        self.text = text
        self.stamp = stamp
        self.contentHash = contentHash
    }
}

/// Renders the nightly receipt as fixed-width monospaced text in the concept sheet's grammar, and
/// stamps it. Deterministic byte-for-byte for identical inputs: number formatting goes through
/// `ByteFormatting` (no locale), the date is broken out with an explicit calendar, and the content
/// hash is SHA-256 over the body above the footer. Nothing here reads the clock or the environment.
public enum ReceiptComposer {
    /// Receipt tape width in characters.
    static let width = 40

    /// Composes and stamps a receipt for one accounting day.
    ///
    /// - Parameters:
    ///   - dayEpoch: local-midnight Unix seconds of the day being closed.
    ///   - totals: the day's per-kind totals.
    ///   - availability: every collector's state at close; all `.running` prints BALANCED.
    ///   - machineName: the machine the books belong to, printed in the header.
    ///   - marginComment: the single dry sentence from `MarginNotes`.
    ///   - calendar: the calendar used to render the header date; defaults to the local calendar.
    ///   - closedInArrears: true when a past day is being closed after the fact; the receipt then
    ///     stamps POSTED IN ARREARS and ignores `availability`, whose live values describe today,
    ///     not the period being closed.
    public static func compose(
        dayEpoch: Int64,
        totals: [MetricKind: Int64],
        availability: [CollectorAvailability],
        machineName: String,
        marginComment: String,
        calendar: Calendar = .current,
        closedInArrears: Bool = false
    ) -> Receipt {
        let ledger = Ledger(totals: totals)
        let stamp = closedInArrears ? ReceiptStamp.postedInArrears : stamp(for: availability)

        var body: [String] = []
        body += masthead()
        body += header(dayEpoch: dayEpoch, machineName: machineName, calendar: calendar)
        body += tokenSection(ledger)
        body += trafficSection(ledger)
        body += storageSection(ledger)
        body += hoursSection(ledger)
        body += laborSection(ledger)
        body += totalsBlock(ledger)
        body += marginBlock(marginComment)
        body += stampBlock(stamp)

        let bodyText = body.joined(separator: "\n")
        let hash = contentHash(of: bodyText)

        var full = body
        full.append(thinRule())
        full.append(row("Content hash", hash))
        full.append(rule())

        return Receipt(text: full.joined(separator: "\n"), stamp: stamp, contentHash: hash)
    }

    /// The stamp for an availability snapshot: BALANCED when every collector was running, otherwise
    /// FLAGGED with the short accounts named in canonical account order.
    public static func stamp(for availability: [CollectorAvailability]) -> ReceiptStamp {
        let shortByFamily = availability.filter { $0.availability != .running }
        guard !shortByFamily.isEmpty else { return .balanced }
        let families = Set(shortByFamily.map(\.family))
        let names = LedgerAccountKind.allCases
            .filter { families.contains($0.family) }
            .map(\.title)
        return .flagged(shortAccounts: names)
    }

    // MARK: - Sections

    private static func masthead() -> [String] {
        [rule(), center("BYTELIFE"), center("DAILY RECONCILIATION"), rule()]
    }

    private static func header(dayEpoch: Int64, machineName: String, calendar: Calendar) -> [String] {
        let date = Date(timeIntervalSince1970: TimeInterval(dayEpoch))
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let dateString = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return [
            row("Date", dateString),
            row("Period", "00:00-23:59"),
            row("Machine", machineName),
            thinRule(),
        ]
    }

    private static func tokenSection(_ ledger: Ledger) -> [String] {
        let account = ledger.account(.token)
        let rate: String
        if let r = ledger.tokenExchangeRate {
            rate = String(format: "%.2f : 1", r)
        } else {
            rate = "n/a"
        }
        return [
            LedgerAccountKind.token.title.uppercased(),
            entry("Tokens Payable", "Dr", ByteFormatting.grouped(account.debit)),
            entry("Tokens Receivable", "Cr", ByteFormatting.grouped(account.credit)),
            entry("Cache memo", "",
                  "\(ByteFormatting.tokens(ledger.cacheCreationTokens)) w / \(ByteFormatting.tokens(ledger.cacheReadTokens)) r"),
            entry("Exchange rate", "", rate),
            thinRule(),
        ]
    }

    private static func trafficSection(_ ledger: Ledger) -> [String] {
        let account = ledger.account(.traffic)
        let netSide = account.net >= 0 ? "Cr" : "Dr"
        return [
            LedgerAccountKind.traffic.title.uppercased(),
            entry("Bytes Remitted", "Dr", ByteFormatting.bytes(account.debit)),
            entry("Bytes Received", "Cr", ByteFormatting.bytes(account.credit)),
            entry("Net flow", netSide, ByteFormatting.bytes(abs(account.net))),
            thinRule(),
        ]
    }

    private static func storageSection(_ ledger: Ledger) -> [String] {
        let account = ledger.account(.storage)
        return [
            LedgerAccountKind.storage.title.uppercased(),
            entry("Writes Posted", "Dr", ByteFormatting.bytes(account.debit)),
            entry("Reads Drawn", "Cr", ByteFormatting.bytes(account.credit)),
            entry("Churn", "", ByteFormatting.bytes(account.churn)),
            thinRule(),
        ]
    }

    private static func hoursSection(_ ledger: Ledger) -> [String] {
        let account = ledger.account(.hours)
        return [
            LedgerAccountKind.hours.title.uppercased(),
            entry("Attention", "Dr", ByteFormatting.hoursMinutes(seconds: account.debit)),
            thinRule(),
        ]
    }

    private static func laborSection(_ ledger: Ledger) -> [String] {
        let account = ledger.account(.labor)
        return [
            LedgerAccountKind.labor.title.uppercased(),
            entry("Keys Struck", "Dr", ByteFormatting.grouped(account.debit)),
            entry("Distance Hauled", "Dr", ByteFormatting.distanceHauled(milliPixels: ledger.mouseMilliPixels)),
            thinRule(),
        ]
    }

    private static func totalsBlock(_ ledger: Ledger) -> [String] {
        [row("POSTED BYTE VOLUME", ByteFormatting.bytes(ledger.runningBalance)), rule()]
    }

    private static func marginBlock(_ comment: String) -> [String] {
        wrap(comment, prefix: "> ") + [thinRule()]
    }

    private static func stampBlock(_ stamp: ReceiptStamp) -> [String] {
        switch stamp {
        case .balanced:
            return [center("* BALANCED *")]
        case .flagged(let accounts):
            return [center("* FLAGGED *"), "Short accounts:"] + accounts.map { "  \($0)" }
        case .postedInArrears:
            return [
                center("* POSTED IN ARREARS *"),
                "Availability for the period was not",
                "retained. Figures are as recorded.",
            ]
        }
    }

    // MARK: - Hashing

    /// SHA-256 over the canonical body text, truncated to the first 16 hex characters.
    static func contentHash(of body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Layout helpers

    private static func rule() -> String { String(repeating: "=", count: width) }
    private static func thinRule() -> String { String(repeating: "-", count: width) }

    private static func center(_ s: String) -> String {
        guard s.count < width else { return s }
        let leading = (width - s.count) / 2
        return String(repeating: " ", count: leading) + s
    }

    /// A two-column line: `left` flush left, `right` flush right, padded to the tape width. When the
    /// two would collide, they are separated by a single space and the line runs long rather than lose
    /// characters.
    private static func row(_ left: String, _ right: String) -> String {
        let gap = width - left.count - right.count
        if gap < 1 { return left + " " + right }
        return left + String(repeating: " ", count: gap) + right
    }

    /// An itemized account line: a two-space indented name in a fixed field, a Dr/Cr marker (or two
    /// blanks for a memo line) in a fixed column, then the value flush right. The fixed columns keep
    /// the markers and the values vertically aligned across every account.
    private static func entry(_ name: String, _ side: String, _ value: String) -> String {
        let nameField = 20
        let sideField = 2
        let left = "  " + name.padding(toLength: nameField, withPad: " ", startingAt: 0)
        let marker = side.isEmpty ? String(repeating: " ", count: sideField) : side
        let valueField = width - left.count - marker.count
        let valueCell = valueField > value.count
            ? String(repeating: " ", count: valueField - value.count) + value
            : " " + value
        return left + marker + valueCell
    }

    /// Word-wraps `text` to the tape width, prefixing every line with `prefix`. Deterministic: it
    /// splits on single spaces and never hyphenates, so identical comments wrap identically.
    private static func wrap(_ text: String, prefix: String) -> [String] {
        let budget = width - prefix.count
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= budget {
                current += " " + word
            } else {
                lines.append(prefix + current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(prefix + current) }
        return lines.isEmpty ? [prefix.trimmingCharacters(in: .whitespaces)] : lines
    }
}
