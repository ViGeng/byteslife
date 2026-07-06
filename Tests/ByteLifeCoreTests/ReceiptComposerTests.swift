import XCTest
@testable import ByteLifeCore

final class ReceiptComposerTests: XCTestCase {
    /// The fixed inputs behind the golden receipt. Shared by the golden and determinism tests so both
    /// exercise the exact same composition.
    private static let goldenTotals: [MetricKind: Int64] = [
        .aiInputTokens: 4_200,
        .aiOutputTokens: 7_560,
        .aiCacheCreationTokens: 1_200_000,
        .aiCacheReadTokens: 3_400_000,
        .networkBytesOut: 1_610_612_736,   // 1.5 GB
        .networkBytesIn: 4_294_967_296,    // 4.0 GB
        .diskBytesWritten: 536_870_912,    // 512 MB
        .diskBytesRead: 2_147_483_648,     // 2.0 GB
        .screenAttentiveSeconds: 24_120,   // 06:42
        .inputKeystrokes: 8_412,
        .inputMouseMilliPixels: 2_600_000_000,
    ]

    private static let goldenComment =
        "Network traffic up 340% versus the trailing average. No judgment. Filing it."

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func allRunning() -> [CollectorAvailability] {
        MetricFamily.allCases.map {
            CollectorAvailability(id: $0.rawValue, family: $0, availability: .running)
        }
    }

    private func composeGolden() -> Receipt {
        ReceiptComposer.compose(
            dayEpoch: 1_783_296_000,   // 2026-07-06 00:00 UTC
            totals: Self.goldenTotals,
            availability: allRunning(),
            machineName: "studio.local",
            marginComment: Self.goldenComment,
            calendar: utcCalendar()
        )
    }

    // MARK: - Determinism and hashing

    func testCompositionIsByteForByteDeterministic() {
        XCTAssertEqual(composeGolden().text, composeGolden().text)
        XCTAssertEqual(composeGolden().contentHash, composeGolden().contentHash)
    }

    func testHashIsSixteenLowercaseHexAndPrintedInFooter() {
        let receipt = composeGolden()
        XCTAssertEqual(receipt.contentHash.count, 16)
        XCTAssertTrue(receipt.contentHash.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertTrue(receipt.text.contains("Content hash"))
        XCTAssertTrue(receipt.text.contains(receipt.contentHash))
    }

    func testHashCoversBodyAndChangesWithContent() {
        let base = composeGolden().contentHash

        // A different margin comment changes the body and therefore the hash.
        let otherComment = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: allRunning(),
            machineName: "studio.local", marginComment: "A different note entirely.", calendar: utcCalendar()
        )
        XCTAssertNotEqual(otherComment.contentHash, base)

        // A different figure changes the hash too.
        var moreTokens = Self.goldenTotals
        moreTokens[.aiInputTokens] = 9_999
        let otherTotals = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: moreTokens, availability: allRunning(),
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar()
        )
        XCTAssertNotEqual(otherTotals.contentHash, base)
    }

    // MARK: - Golden fixture

    func testMatchesGoldenFixture() throws {
        guard let url = Bundle.module.url(
            forResource: "receipt_golden", withExtension: "txt", subdirectory: "Fixtures"
        ) else {
            return XCTFail("missing golden fixture")
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        // The fixture is stored with a trailing newline; the composed text has none.
        XCTAssertEqual(composeGolden().text + "\n", expected)
    }

    // MARK: - Stamp decision

    func testStampBalancedWhenEveryCollectorRunning() {
        let receipt = composeGolden()
        XCTAssertEqual(receipt.stamp, .balanced)
        XCTAssertTrue(receipt.text.contains("* BALANCED *"))
        XCTAssertFalse(receipt.text.contains("FLAGGED"))
    }

    func testStampFlaggedNamesTheShortAccount() {
        var availability = allRunning()
        availability[0] = CollectorAvailability(id: "ai", family: .ai, availability: .sourceMissing)
        let receipt = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: availability,
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar()
        )
        XCTAssertEqual(receipt.stamp, .flagged(shortAccounts: ["Token Account"]))
        XCTAssertTrue(receipt.text.contains("* FLAGGED *"))
        XCTAssertTrue(receipt.text.contains("Token Account"))
    }

    func testStampFlaggedListsAccountsInCanonicalOrder() {
        // Input (labor) is passed before AI (token) to prove the output order is canonical, not input.
        let availability = [
            CollectorAvailability(id: "input", family: .input, availability: .needsPermission),
            CollectorAvailability(id: "ai", family: .ai, availability: .sourceMissing),
            CollectorAvailability(id: "network", family: .network, availability: .running),
            CollectorAvailability(id: "disk", family: .disk, availability: .running),
            CollectorAvailability(id: "screen", family: .screen, availability: .running),
        ]
        XCTAssertEqual(
            ReceiptComposer.stamp(for: availability),
            .flagged(shortAccounts: ["Token Account", "Labor Account"])
        )
    }

    func testStampStorageValues() {
        XCTAssertEqual(ReceiptStamp.balanced.storageValue, "BALANCED")
        XCTAssertEqual(ReceiptStamp.flagged(shortAccounts: ["Token Account"]).storageValue, "FLAGGED")
        XCTAssertEqual(ReceiptStamp.postedInArrears.storageValue, "POSTED IN ARREARS")
    }

    /// A past-day close must not bake today's collector states into the immutable artifact: even with
    /// collectors short right now, the arrears receipt discloses the late posting instead of printing
    /// FLAGGED with spurious short accounts (or an unearned BALANCED).
    func testArrearsCloseIgnoresLiveAvailability() {
        var availability = allRunning()
        availability[4] = CollectorAvailability(id: "input", family: .input, availability: .needsPermission)
        let receipt = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: availability,
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar(),
            closedInArrears: true
        )
        XCTAssertEqual(receipt.stamp, .postedInArrears)
        XCTAssertTrue(receipt.text.contains("* POSTED IN ARREARS *"))
        XCTAssertTrue(receipt.text.contains("Availability for the period was not"))
        XCTAssertFalse(receipt.text.contains("FLAGGED"))
        XCTAssertFalse(receipt.text.contains("* BALANCED *"))
        XCTAssertFalse(receipt.text.contains("Short accounts"))
    }

    func testArrearsCompositionIsDeterministicAndHashed() {
        let compose = {
            ReceiptComposer.compose(
                dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: self.allRunning(),
                machineName: "studio.local", marginComment: Self.goldenComment,
                calendar: self.utcCalendar(), closedInArrears: true
            )
        }
        XCTAssertEqual(compose().text, compose().text)
        XCTAssertTrue(compose().text.contains(compose().contentHash))
        // The arrears stamp is part of the hashed body, so it differs from the live-close hash.
        XCTAssertNotEqual(compose().contentHash, composeGolden().contentHash)
    }

    // MARK: - Fixture generation (skipped; used once to emit the golden file)

    func testEmitGolden() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EMIT_GOLDEN"] != nil)
        let path = ProcessInfo.processInfo.environment["EMIT_GOLDEN"]!
        try (composeGolden().text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
