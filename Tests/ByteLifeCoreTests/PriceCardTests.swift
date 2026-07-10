import XCTest
@testable import ByteLifeCore

final class PriceCardTests: XCTestCase {

    private func row(
        source: String = "claudeCode",
        model: String,
        input: Int64 = 0,
        output: Int64 = 0,
        cacheCreation: Int64 = 0,
        cacheRead: Int64 = 0
    ) -> AIModelTotal {
        AIModelTotal(source: source, model: model, input: input, output: output,
                     cacheCreation: cacheCreation, cacheRead: cacheRead)
    }

    // MARK: - Per-provider arithmetic (hand-computed)

    func testAnthropicArithmetic() {
        // 1M*10 + 0.2M*50 + 0.4M*12.50 + 5M*1.00, per million = 10 + 10 + 5 + 5.
        let summary = PriceCard.bundled.cost(of: [row(
            model: "claude-fable-5",
            input: 1_000_000, output: 200_000, cacheCreation: 400_000, cacheRead: 5_000_000
        )])
        XCTAssertEqual(summary.total, 30.0, accuracy: 1e-9)
        XCTAssertEqual(summary.models.first?.cost ?? 0, 30.0, accuracy: 1e-9)
        XCTAssertEqual(summary.unpricedTokens, 0)
        XCTAssertEqual(summary.asOf, "2026-07-07")
    }

    func testOpenAIArithmetic() {
        // Codex records cached tokens INSIDE input (2M input of which 1.5M cached): the uncached 0.5M
        // bills at $1.75, the cached 1.5M at $0.175, and 0.5M output at $14 = 0.875 + 0.2625 + 7.
        let summary = PriceCard.bundled.cost(of: [row(
            source: "codex", model: "gpt-5.3-codex",
            input: 2_000_000, output: 500_000, cacheRead: 1_500_000
        )])
        XCTAssertEqual(summary.total, 8.1375, accuracy: 1e-9)
    }

    func testGoogleArithmetic() {
        // Gemini records cached inside input too (3M of which 2M cached):
        // 1M*2.00 + 0.25M*12.00 + 2M*0.20 = 2 + 3 + 0.4.
        let summary = PriceCard.bundled.cost(of: [row(
            source: "gemini", model: "gemini-3-pro-preview",
            input: 3_000_000, output: 250_000, cacheRead: 2_000_000
        )])
        XCTAssertEqual(summary.total, 5.4, accuracy: 1e-9)
    }

    /// Cached input for a cache-inclusive source bills exactly once at the cache-read rate, never at
    /// the input rate plus the cache-read rate (a dishonest 110 percent of input).
    func testCacheInclusiveInputNeverDoubleCharges() {
        // A fully cached Codex prompt: 1M input, all of it cached, no output.
        let summary = PriceCard.bundled.cost(of: [row(
            source: "codex", model: "gpt-5.3-codex", input: 1_000_000, cacheRead: 1_000_000
        )])
        XCTAssertEqual(summary.total, 0.175, accuracy: 1e-9)
        // The token figure counts the channel once: 1M, not 2M.
        XCTAssertEqual(summary.models.first?.tokens, 1_000_000)
    }

    /// Anthropic records the cache channels separately from input, so a Claude row bills input in full
    /// alongside its cache reads and counts both channels in the token figure.
    func testAnthropicCacheChannelsStaySeparate() {
        let summary = PriceCard.bundled.cost(of: [row(
            model: "claude-fable-5", input: 1_000_000, cacheRead: 1_000_000
        )])
        XCTAssertEqual(summary.total, 11.0, accuracy: 1e-9)   // $10 input + $1 cache read
        XCTAssertEqual(summary.models.first?.tokens, 2_000_000)
    }

    /// A malformed cache-inclusive row (cacheRead beyond input) clamps the uncached input at zero
    /// instead of billing negative tokens.
    func testCacheBeyondInputClampsAtZero() {
        let summary = PriceCard.bundled.cost(of: [row(
            source: "codex", model: "gpt-5.3-codex", input: 1_000_000, cacheRead: 4_000_000
        )])
        XCTAssertEqual(summary.total, 0.7, accuracy: 1e-9)   // 4M * $0.175 only
    }

    func testHaikuAndSonnetRates() {
        let summary = PriceCard.bundled.cost(of: [
            row(model: "claude-haiku-4-5", input: 1_000_000, output: 1_000_000),   // 1 + 5
            row(model: "claude-sonnet-4-6", input: 1_000_000, output: 1_000_000),  // 3 + 15
        ])
        XCTAssertEqual(summary.total, 24.0, accuracy: 1e-9)
    }

    // MARK: - Prefix matching

    func testDatedVariantPricesAsBaseModel() {
        let price = PriceCard.bundled.price(forModel: "claude-opus-4-6-20260115")
        XCTAssertEqual(price?.input, 5)
        XCTAssertEqual(price?.output, 25)
    }

    func testLongestPrefixWinsForMini() {
        // "gpt-5.4-mini" is prefixed by both "gpt-5.4" and "gpt-5.4-mini"; the longer key wins.
        XCTAssertEqual(PriceCard.bundled.price(forModel: "gpt-5.4-mini")?.input, 0.75)
        XCTAssertEqual(PriceCard.bundled.price(forModel: "gpt-5.4-mini-2026-05-01")?.output, 4.50)
        XCTAssertEqual(PriceCard.bundled.price(forModel: "gpt-5.4")?.input, 2.50)
    }

    func testLongestPrefixTieOnCustomCard() {
        // Both keys prefix the stored string; the longer, more specific key must win.
        let card = PriceCard(asOf: "2026-07-07", prices: [
            "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
            "claude-opus-4-8-turbo": ModelPrice(input: 9, output: 45, cacheRead: 0.9, cacheWrite: 11.25),
        ])
        XCTAssertEqual(card.price(forModel: "claude-opus-4-8-turbo-20260101")?.input, 9)
        XCTAssertEqual(card.price(forModel: "claude-opus-4-8-20260101")?.input, 5)
    }

    func testPrefixRequiresNameBoundary() {
        // "gpt-5.41" is not a suffixed variant of "gpt-5.4" and must stay unpriced.
        XCTAssertNil(PriceCard.bundled.price(forModel: "gpt-5.41"))
    }

    func testNormalizationOfCaseWhitespaceAndModelsPrefix() {
        XCTAssertEqual(PriceCard.bundled.price(forModel: " Claude-Fable-5 ")?.input, 10)
        XCTAssertEqual(PriceCard.bundled.price(forModel: "models/gemini-3-flash-preview")?.input, 0.50)
    }

    // MARK: - The unpriced fallback

    func testUnpricedModelExcludedFromTotalAndDisclosed() {
        let summary = PriceCard.bundled.cost(of: [
            row(model: "claude-haiku-4-5", input: 1_000_000, output: 0), // $1.00
            row(model: "unknown", input: 2_000, output: 100),
        ])
        XCTAssertEqual(summary.total, 1.0, accuracy: 1e-9)
        XCTAssertEqual(summary.unpricedTokens, 2_100)
        XCTAssertEqual(summary.unpricedDisclosure, "2.1K tokens unpriced")
        let unknown = summary.models.first { $0.model == "unknown" }
        XCTAssertNil(unknown?.cost)
        XCTAssertEqual(unknown?.tokens, 2_100)
    }

    func testFullyPricedDayHasNoDisclosure() {
        let summary = PriceCard.bundled.cost(of: [row(model: "claude-fable-5", input: 100)])
        XCTAssertNil(summary.unpricedDisclosure)
    }

    func testPricedRowsOrderBeforeUnpriced() {
        let summary = PriceCard.bundled.cost(of: [
            row(model: "mystery-model", input: 9_000_000),
            row(model: "claude-haiku-4-5", input: 1_000_000),          // $1
            row(model: "claude-fable-5", input: 1_000_000),            // $10
        ])
        XCTAssertEqual(summary.models.map(\.model),
                       ["claude-fable-5", "claude-haiku-4-5", "mystery-model"])
    }

    // MARK: - Multi-day aggregation

    /// Costs are linear in the token counts, so pricing a period's summed model rows equals summing the
    /// daily figures — the equivalence the aggregate surfaces rely on when they price one batched query.
    func testPricingSummedRowsEqualsSummingDailyCosts() {
        let card = PriceCard.bundled
        let day1 = card.cost(of: [
            row(model: "claude-fable-5", input: 1_000_000),
            row(model: "unknown", input: 1_000),
        ])
        let day2 = card.cost(of: [
            row(model: "claude-fable-5", output: 200_000),
            row(source: "codex", model: "gpt-5.3-codex", input: 2_000_000, cacheRead: 500_000),
            row(model: "unknown", output: 500),
        ])
        let period = card.cost(of: [
            row(model: "claude-fable-5", input: 1_000_000, output: 200_000),
            row(source: "codex", model: "gpt-5.3-codex", input: 2_000_000, cacheRead: 500_000),
            row(model: "unknown", input: 1_000, output: 500),
        ])

        XCTAssertEqual(period.total, day1.total + day2.total, accuracy: 1e-9)
        XCTAssertEqual(period.unpricedTokens, day1.unpricedTokens + day2.unpricedTokens)
        XCTAssertEqual(period.models.count, 3)

        let fable = period.models.first { $0.model == "claude-fable-5" }
        XCTAssertEqual(fable?.cost ?? 0, 20.0, accuracy: 1e-9)
        XCTAssertEqual(fable?.tokens, 1_200_000)
        XCTAssertNil(period.models.first { $0.model == "unknown" }?.cost)
    }

    // MARK: - Dollar formatting

    func testDollarFormatting() {
        XCTAssertEqual(PriceCard.dollars(0), "$0.00")
        XCTAssertEqual(PriceCard.dollars(0.004), "<$0.01")
        XCTAssertEqual(PriceCard.dollars(0.005), "$0.01")
        XCTAssertEqual(PriceCard.dollars(3.456), "$3.46")
        XCTAssertEqual(PriceCard.dollars(42.0), "$42.00")
        XCTAssertEqual(PriceCard.dollars(1234.5), "$1,234.50")
    }
}
