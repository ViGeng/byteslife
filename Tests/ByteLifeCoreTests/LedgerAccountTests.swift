import XCTest
@testable import ByteLifeCore

final class LedgerAccountTests: XCTestCase {
    /// The full fixture used across the account-mapping assertions.
    private let totals: [MetricKind: Int64] = [
        .aiInputTokens: 4_200,
        .aiOutputTokens: 7_560,
        .aiCacheCreationTokens: 1_200_000,
        .aiCacheReadTokens: 3_400_000,
        .networkBytesOut: 1_610_612_736,   // 1.5 GB
        .networkBytesIn: 4_294_967_296,    // 4.0 GB
        .diskBytesWritten: 536_870_912,    // 512 MB
        .diskBytesRead: 2_147_483_648,     // 2.0 GB
        .screenAttentiveSeconds: 24_120,
        .inputKeystrokes: 8_412,
        .inputMouseMilliPixels: 2_600_000_000,
    ]

    func testAccountKindMapsFamilyBothWays() {
        for kind in LedgerAccountKind.allCases {
            XCTAssertEqual(LedgerAccountKind(family: kind.family), kind)
        }
        XCTAssertEqual(LedgerAccountKind(family: .ai), .token)
        XCTAssertEqual(LedgerAccountKind(family: .input), .labor)
    }

    func testExactAccountTitles() {
        XCTAssertEqual(LedgerAccountKind.token.title, "Token Account")
        XCTAssertEqual(LedgerAccountKind.traffic.title, "Traffic Account")
        XCTAssertEqual(LedgerAccountKind.storage.title, "Storage Account")
        XCTAssertEqual(LedgerAccountKind.hours.title, "Hours Under the Lamp")
        XCTAssertEqual(LedgerAccountKind.labor.title, "Labor Account")
    }

    func testSideRulesOutflowIsDebitInflowIsCredit() {
        let ledger = Ledger(totals: totals)

        // Tokens prompted (out) post as debit; generated (back) post as credit.
        XCTAssertEqual(ledger.account(.token).debit, 4_200)
        XCTAssertEqual(ledger.account(.token).credit, 7_560)
        // Bytes sent post as debit; received as credit.
        XCTAssertEqual(ledger.account(.traffic).debit, 1_610_612_736)
        XCTAssertEqual(ledger.account(.traffic).credit, 4_294_967_296)
        // Writes post as debit; reads as credit.
        XCTAssertEqual(ledger.account(.storage).debit, 536_870_912)
        XCTAssertEqual(ledger.account(.storage).credit, 2_147_483_648)
    }

    func testExpenseAccountsCarryNoCredit() {
        let ledger = Ledger(totals: totals)
        XCTAssertEqual(ledger.account(.hours).debit, 24_120)
        XCTAssertEqual(ledger.account(.hours).credit, 0)
        XCTAssertEqual(ledger.account(.labor).debit, 8_412)
        XCTAssertEqual(ledger.account(.labor).credit, 0)
    }

    func testCacheTokensNeverEnterPayable() {
        let ledger = Ledger(totals: totals)
        // Payable is the prompted count only; the far larger cache traffic stays on the memo figures.
        XCTAssertEqual(ledger.account(.token).debit, 4_200)
        XCTAssertEqual(ledger.cacheCreationTokens, 1_200_000)
        XCTAssertEqual(ledger.cacheReadTokens, 3_400_000)
    }

    func testNetAndChurn() {
        let ledger = Ledger(totals: totals)
        XCTAssertEqual(ledger.account(.token).net, 7_560 - 4_200)
        XCTAssertEqual(ledger.account(.traffic).net, 4_294_967_296 - 1_610_612_736)
        XCTAssertEqual(ledger.account(.storage).churn, 536_870_912 + 2_147_483_648)
    }

    func testRunningBalanceIsPostedByteVolumeOnly() {
        let ledger = Ledger(totals: totals)
        let expected: Int64 = 1_610_612_736 + 4_294_967_296 + 536_870_912 + 2_147_483_648
        XCTAssertEqual(ledger.runningBalance, expected)   // exactly 8 GiB
        XCTAssertEqual(ledger.runningBalance, 8 * 1024 * 1024 * 1024)
        // Tokens, hours, and labor never fold into the running balance.
        let noBytes = Ledger(totals: [.aiInputTokens: 9_999, .screenAttentiveSeconds: 9_999, .inputKeystrokes: 9_999])
        XCTAssertEqual(noBytes.runningBalance, 0)
    }

    func testExchangeRateIsGeneratedOverPrompted() {
        let ledger = Ledger(totals: totals)
        XCTAssertEqual(ledger.tokenExchangeRate ?? 0, 7_560.0 / 4_200.0, accuracy: 1e-9)
        // Undefined, not zero, when nothing was prompted.
        XCTAssertNil(Ledger(totals: [.aiOutputTokens: 100]).tokenExchangeRate)
    }

    func testMissingKindsReadAsZero() {
        let empty = Ledger(totals: [:])
        for account in empty.accounts {
            XCTAssertEqual(account.debit, 0)
            XCTAssertEqual(account.credit, 0)
        }
        XCTAssertEqual(empty.runningBalance, 0)
        XCTAssertNil(empty.tokenExchangeRate)
    }

    func testMetersConversionAt220PixelsPerInch() {
        // 220,000 px == 1000 inches == 25.4 m at the recorded assumption.
        XCTAssertEqual(ByteFormatting.meters(milliPixels: 220_000_000), 25.4, accuracy: 1e-9)
        XCTAssertEqual(ByteFormatting.assumedPixelsPerInch, 220.0)
        // Zero travel is zero meters.
        XCTAssertEqual(ByteFormatting.meters(milliPixels: 0), 0, accuracy: 1e-12)
    }

    func testDistanceHauledFormatting() {
        XCTAssertEqual(ByteFormatting.distanceHauled(milliPixels: 0), "0 m")
        XCTAssertEqual(ByteFormatting.distanceHauled(milliPixels: 2_600_000_000), "300 m")
        // Above a kilometer switches unit.
        XCTAssertEqual(ByteFormatting.distanceHauled(milliPixels: 26_000_000_000), "3.0 km")
    }

    func testGroupedAndHoursMinutesFormatting() {
        XCTAssertEqual(ByteFormatting.grouped(0), "0")
        XCTAssertEqual(ByteFormatting.grouped(4_200), "4,200")
        XCTAssertEqual(ByteFormatting.grouped(8_412), "8,412")
        XCTAssertEqual(ByteFormatting.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(ByteFormatting.grouped(-4_200), "-4,200")

        XCTAssertEqual(ByteFormatting.hoursMinutes(seconds: 0), "00:00")
        XCTAssertEqual(ByteFormatting.hoursMinutes(seconds: 24_120), "06:42")
        XCTAssertEqual(ByteFormatting.hoursMinutes(seconds: 3_600), "01:00")
    }
}
