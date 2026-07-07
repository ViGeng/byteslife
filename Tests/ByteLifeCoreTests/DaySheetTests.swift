import XCTest
@testable import ByteLifeCore

final class DaySheetTests: XCTestCase {
    private let running: [MetricFamily: Availability] = [
        .ai: .running, .network: .running, .disk: .running, .screen: .running, .input: .running,
    ]

    private func totals() -> [MetricKind: Int64] {
        [
            .aiInputTokens: 1_000, .aiOutputTokens: 4_000,
            .aiCacheCreationTokens: 200, .aiCacheReadTokens: 90_000,
            .networkBytesOut: 500, .networkBytesIn: 2_000,
            .diskBytesWritten: 3_000, .diskBytesRead: 1_000,
            .screenAttentiveSeconds: 3_720,
            .inputKeystrokes: 8_000, .inputMouseMilliPixels: 5_000_000,
        ]
    }

    private func account(_ sheet: DaySheet, _ kind: LedgerAccountKind) -> DaySheetAccount {
        sheet.accounts.first { $0.kind == kind }!
    }

    func testAccountsAreTheFiveInCanonicalOrder() {
        let sheet = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: nil)
        XCTAssertEqual(sheet.accounts.map(\.kind), LedgerAccountKind.allCases)
        XCTAssertEqual(account(sheet, .token).title, "Token Account")
        XCTAssertEqual(account(sheet, .hours).title, "Hours Under the Lamp")
    }

    func testExpenseAccountsHaveOnlyDebitLines() {
        let sheet = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: nil)
        for kind in [LedgerAccountKind.hours, .labor] {
            let sides = Set(account(sheet, kind).lines.map(\.side))
            XCTAssertFalse(sides.contains(.credit), "\(kind) must never fake a credit side")
            XCTAssertTrue(sides.contains(.debit))
        }
        // Labor books two debit sub-lines: keystrokes and mouse travel.
        XCTAssertEqual(account(sheet, .labor).lines.filter { $0.side == .debit }.count, 2)
    }

    func testTokenAccountShowsExchangeRateAndCacheMemo() {
        let sheet = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: nil)
        let lines = account(sheet, .token).lines
        XCTAssertTrue(lines.contains { $0.label == "Tokens Payable" && $0.side == .debit })
        XCTAssertTrue(lines.contains { $0.label == "Tokens Receivable" && $0.side == .credit })
        // 4000 generated over 1000 prompted reads 4.00 : 1.
        XCTAssertTrue(lines.contains { $0.label == "Exchange rate" && $0.value == "4.00 : 1" })
        XCTAssertTrue(lines.contains { $0.label == "Cache" && $0.side == .memo })
    }

    func testTokenAccountAlwaysDisclosesPartialSourcesWhenRunning() {
        let sheet = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: nil)
        XCTAssertEqual(account(sheet, .token).disclosure, DaySheet.partialTokenSources)
    }

    func testTokenAccountSourceAwareDisclosureWhenPartial() {
        let sources = [
            AISourceStatus(displayName: "Claude Code", isReporting: true),
            AISourceStatus(displayName: "Codex", isReporting: true),
            AISourceStatus(displayName: "Gemini", isReporting: false),
        ]
        let sheet = DaySheet.build(
            totals: totals(), availabilityByFamily: running, reconciliation: nil, aiSources: sources
        )
        XCTAssertEqual(
            account(sheet, .token).disclosure,
            "Partial: 2 of 3 sources reporting. Claude Code, Codex reporting. Gemini not yet opened."
        )
    }

    func testTokenAccountSourceAwareDisclosureWhenAllReporting() {
        let sources = [
            AISourceStatus(displayName: "Claude Code", isReporting: true),
            AISourceStatus(displayName: "Codex", isReporting: true),
            AISourceStatus(displayName: "Gemini", isReporting: true),
        ]
        let sheet = DaySheet.build(
            totals: totals(), availabilityByFamily: running, reconciliation: nil, aiSources: sources
        )
        XCTAssertEqual(
            account(sheet, .token).disclosure,
            "All 3 sources reporting: Claude Code, Codex, Gemini."
        )
    }

    func testMissingSourceReadsAsAccountNotYetOpened() {
        var availability = running
        availability[.ai] = .sourceMissing
        let sheet = DaySheet.build(totals: [:], availabilityByFamily: availability, reconciliation: nil)
        XCTAssertEqual(account(sheet, .token).disclosure, DaySheet.notYetOpened)
    }

    func testNeedsPermissionCarriesNoPassiveDisclosure() {
        var availability = running
        availability[.input] = .needsPermission
        let sheet = DaySheet.build(totals: totals(), availabilityByFamily: availability, reconciliation: nil)
        XCTAssertNil(account(sheet, .labor).disclosure)
        XCTAssertEqual(account(sheet, .labor).availability, .needsPermission)
    }

    func testRunningBalanceIsTrafficAndStorageChurnOnly() {
        let sheet = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: nil)
        // (500 + 2000) traffic churn + (3000 + 1000) storage churn = 6500 bytes.
        XCTAssertEqual(sheet.postedByteVolume, ByteFormatting.bytes(6_500))
    }

    func testPostedStateReflectsReconciliation() {
        let open = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: nil)
        XCTAssertFalse(open.isPosted)
        XCTAssertNil(open.stamp)

        let reconciliation = Reconciliation(
            dayEpoch: 0, closedAt: 1, receiptText: "r", contentHash: "h", stamp: "BALANCED", comment: "c"
        )
        let posted = DaySheet.build(totals: totals(), availabilityByFamily: running, reconciliation: reconciliation)
        XCTAssertTrue(posted.isPosted)
        XCTAssertEqual(posted.stamp, "BALANCED")
    }
}
