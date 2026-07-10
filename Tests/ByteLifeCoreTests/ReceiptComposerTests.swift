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
        // Accessory figures booked in the AUXILIARY section.
        .energyMilliwattHours: 45_600,     // 45.6 Wh
        .filesTouched: 1_284,
        .screenUnlocks: 12,
        .attentionSessions: 34,
        .commandsRun: 217,
        .lidOpens: 6,
        .systemWakes: 9,
    ]

    /// The accessory figures the AUXILIARY section carries beyond the totals dictionary.
    private static let goldenDistinctHosts = 27
    private static let goldenTopApp: (name: String, seconds: Int64) = (name: "Xcode", seconds: 9_000)

    /// The day's notional AI cost behind the golden Token Account lines: one priced Anthropic model
    /// carrying the token totals above (4,000 x $10 + 7,000 x $50 + 3.4M x $1.00 + 1.2M x $12.50, per
    /// million: $18.79) plus a local model no card prices, so the golden receipt books the unpriced
    /// disclosure (760 tokens) too.
    private static let goldenCost = PriceCard.bundled.cost(of: [
        AIModelTotal(source: "claudeCode", model: "claude-fable-5-20260501",
                     input: 4_000, output: 7_000, cacheCreation: 1_200_000, cacheRead: 3_400_000),
        AIModelTotal(source: "gemini", model: "local-gemma",
                     input: 200, output: 560, cacheCreation: 0, cacheRead: 0),
    ])

    /// The golden trailing day: exactly half of the golden day's figures, recorded seven times, so
    /// every Composite component ratio is 2.0 and the index reads 200.
    private static let goldenTrailingDay = goldenTotals.mapValues { $0 / 2 }

    /// The golden Composite, built through the real path over the trailing history above.
    private static let goldenComposite: Composite = {
        var history: [Int64: [MetricKind: Int64]] = [:]
        for i in 1...7 { history[1_783_296_000 - Int64(i) * 86_400] = goldenTrailingDay }
        return Composite.build(dayEpoch: 1_783_296_000, todayTotals: goldenTotals, history: history)
    }()

    /// The golden margin comment comes from the real rule engine over the same inputs, so the golden
    /// receipt is a combination the production close path can actually emit: an index of 200 fires the
    /// composite rule, which outranks the single-series variance rule.
    private static let goldenComment = MarginNotes.comment(
        today: goldenTotals,
        trailing: Array(repeating: goldenTrailingDay, count: 7),
        composite: goldenComposite
    )

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
            calendar: utcCalendar(),
            auxDistinctHosts: Self.goldenDistinctHosts,
            auxTopApp: Self.goldenTopApp,
            aiCost: Self.goldenCost,
            composite: Self.goldenComposite
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

    // MARK: - Notional cost and Composite lines

    func testTokenSectionBooksNotionalCostAtListPrices() {
        let text = composeGolden().text
        XCTAssertTrue(text.contains("Notional cost (list)"))
        XCTAssertTrue(text.contains("$18.79"))
        // The list-price framing with the card's as-of date, once on the surface.
        XCTAssertTrue(text.contains("At list prices as of"))
        XCTAssertTrue(text.contains("2026-07-07"))
        // The unpriced model's tokens are disclosed, never silently valued at zero.
        XCTAssertTrue(text.contains("Tokens unpriced"))
        XCTAssertTrue(text.contains("760"))
    }

    func testTotalsBlockBooksTheComposite() {
        XCTAssertTrue(composeGolden().text.contains("Composite vs 28-day median: 200"))
    }

    func testCostAndCompositeChangeTheHash() {
        let base = composeGolden().contentHash
        let without = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: allRunning(),
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar(),
            auxDistinctHosts: Self.goldenDistinctHosts, auxTopApp: Self.goldenTopApp
        )
        XCTAssertNotEqual(without.contentHash, base)
    }

    /// A compose without the iteration-10 inputs keeps the earlier receipt shape: no cost lines and no
    /// Composite line, so nothing about older compositions is silently re-narrated. The comment is a
    /// literal here because the golden comment itself now speaks of the Composite.
    func testWithoutCostAndCompositeTheLinesAreOmitted() {
        let text = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: allRunning(),
            machineName: "studio.local",
            marginComment: "Books balanced against the day. Nothing stands out. Filed as usual.",
            calendar: utcCalendar()
        ).text
        XCTAssertFalse(text.contains("Notional cost"))
        XCTAssertFalse(text.contains("Composite"))
    }

    /// A collecting-state Composite books its honest wording, wrapped to the tape width.
    func testCollectingCompositeWrapsHonestly() {
        let text = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: allRunning(),
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar(),
            composite: .collecting(recordedDays: 3)
        ).text
        // The long collecting line wraps at the tape width, so its halves land on adjacent lines.
        XCTAssertTrue(text.contains("Composite vs 28-day median: collecting"))
        XCTAssertTrue(text.contains("baseline (3 of 5 days)"))
        XCTAssertTrue(text.split(separator: "\n").allSatisfy { $0.count <= 40 })
    }

    // MARK: - Auxiliary section

    func testAuxiliarySectionBooksTheAccessoryFigures() {
        let text = composeGolden().text
        XCTAssertTrue(text.contains("AUXILIARY"))
        XCTAssertTrue(text.contains("Energy"))
        XCTAssertTrue(text.contains("45.6 Wh"))
        XCTAssertTrue(text.contains("Files Touched"))
        XCTAssertTrue(text.contains(ByteFormatting.grouped(1_284)))   // 1,284
        XCTAssertTrue(text.contains("Hosts Contacted"))
        XCTAssertTrue(text.contains("27"))
        XCTAssertTrue(text.contains("Unlocks"))
        XCTAssertTrue(text.contains("Sessions"))
        XCTAssertTrue(text.contains("Commands Run"))
        XCTAssertTrue(text.contains(ByteFormatting.grouped(217)))
        XCTAssertTrue(text.contains("Lid Opens"))
        XCTAssertTrue(text.contains("Wakes"))
        XCTAssertTrue(text.contains("Top App"))
        // The top app reads as one line: short name plus its time.
        XCTAssertTrue(text.contains("Xcode \(ByteFormatting.duration(seconds: 9_000))"))
    }

    func testAuxiliarySectionFallsBackToDashWithoutATopApp() {
        let receipt = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: [:], availability: allRunning(),
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar()
        )
        XCTAssertTrue(receipt.text.contains("AUXILIARY"))
        // No focus on file: the top-app line dashes, and the zeroed figures still book.
        XCTAssertTrue(receipt.text.contains("Top App"))
        XCTAssertTrue(receipt.text.contains("0.0 Wh"))
    }

    func testAuxiliaryFiguresChangeTheHash() {
        let base = composeGolden().contentHash
        let moreHosts = ReceiptComposer.compose(
            dayEpoch: 1_783_296_000, totals: Self.goldenTotals, availability: allRunning(),
            machineName: "studio.local", marginComment: Self.goldenComment, calendar: utcCalendar(),
            auxDistinctHosts: 99, auxTopApp: Self.goldenTopApp
        )
        XCTAssertNotEqual(moreHosts.contentHash, base)
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
