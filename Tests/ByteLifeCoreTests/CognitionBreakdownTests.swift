import XCTest
@testable import ByteLifeCore

final class CognitionBreakdownTests: XCTestCase {
    private func model(_ source: String, _ model: String, input: Int64, output: Int64,
                       cache: Int64 = 0) -> AIModelTotal {
        AIModelTotal(source: source, model: model, input: input, output: output,
                     cacheCreation: cache, cacheRead: cache)
    }

    /// Models rank by prompted+generated tokens, heaviest first, each with a proportional bar and a
    /// source-prefixed short label.
    func testModelsRankByTokensWithProportionalBars() {
        let breakdown = CognitionBreakdown.build(
            modelTotals: [
                model("gemini", "gemini-3-pro-preview", input: 1_000, output: 500),
                model("claudeCode", "claude-opus-4-8", input: 6_000, output: 4_000),
                model("codex", "gpt-5.3-codex", input: 2_000, output: 1_000),
            ],
            sessionStats: nil
        )
        XCTAssertEqual(breakdown.models.map(\.label),
                       ["claude/opus-4-8", "codex/5.3-codex", "gemini/3-pro-preview"])
        XCTAssertEqual(breakdown.models[0].tokens, 10_000)
        XCTAssertEqual(breakdown.models[0].fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(breakdown.models[1].tokens, 3_000)
        XCTAssertEqual(breakdown.models[1].fraction, 0.3, accuracy: 0.0001)
        XCTAssertEqual(breakdown.models[0].tokenLabel, "10.0K")
    }

    /// Cache tokens do not count toward the bar: a model that only moved cache traffic is dropped.
    func testCacheOnlyModelIsDropped() {
        let breakdown = CognitionBreakdown.build(
            modelTotals: [
                model("claudeCode", "claude-opus-4-8", input: 0, output: 0, cache: 50_000),
                model("claudeCode", "claude-haiku-4-5", input: 100, output: 200),
            ],
            sessionStats: nil
        )
        XCTAssertEqual(breakdown.models.map(\.label), ["claude/haiku-4-5"])
    }

    /// A cache-inclusive source (Codex, Gemini) records cached tokens inside its input channel; the bar
    /// still reads only the uncached prompted tokens plus output.
    func testCacheInclusiveInputExcludedFromBars() {
        let breakdown = CognitionBreakdown.build(
            modelTotals: [AIModelTotal(source: "codex", model: "gpt-5.3-codex",
                                       input: 1_000, output: 200, cacheCreation: 0, cacheRead: 900)],
            sessionStats: nil
        )
        XCTAssertEqual(breakdown.models.first?.tokens, 300)   // (1,000 - 900) + 200
    }

    /// The top list is capped by the limit.
    func testTopListIsCapped() {
        let totals = (0..<8).map { model("codex", "gpt-m\($0)", input: Int64(100 * ($0 + 1)), output: 0) }
        let breakdown = CognitionBreakdown.build(modelTotals: totals, sessionStats: nil, limit: 3)
        XCTAssertEqual(breakdown.models.count, 3)
    }

    /// The session memo reads the count, average, and longest; it singularizes at one and drops entirely
    /// when no session opened or no statistics are supplied.
    func testSessionMemo() {
        XCTAssertEqual(
            CognitionBreakdown.sessionMemo(AISessionStats(count: 7, averageLength: 1_440, longestLength: 4_320)),
            "7 sessions · avg 24m · longest 1h 12m"
        )
        XCTAssertEqual(
            CognitionBreakdown.sessionMemo(AISessionStats(count: 1, averageLength: 600, longestLength: 600)),
            "1 session · avg 10m · longest 10m"
        )
        XCTAssertNil(CognitionBreakdown.sessionMemo(AISessionStats(count: 0, averageLength: 0, longestLength: 0)))
        XCTAssertNil(CognitionBreakdown.sessionMemo(nil))
    }

    /// An empty ledger yields no models and no memo.
    func testEmptyLedger() {
        let breakdown = CognitionBreakdown.build(modelTotals: [], sessionStats: nil)
        XCTAssertTrue(breakdown.models.isEmpty)
        XCTAssertNil(breakdown.sessionMemo)
    }

    /// With a cost summary supplied, each displayed row carries its own cost figure, an unmatched model
    /// reads "unpriced" (disclosed, never a silent zero), and the card-level line and footnote carry the
    /// priced total, the list-price framing, and the unpriced disclosure.
    func testCostColumnCardLineAndDisclosure() {
        let rows = [
            model("claudeCode", "claude-haiku-4-5", input: 1_000_000, output: 0),
            model("codex", "mystery-9", input: 500, output: 500),
        ]
        let cost = PriceCard.bundled.cost(of: rows)
        let breakdown = CognitionBreakdown.build(modelTotals: rows, sessionStats: nil, cost: cost)

        // haiku: 1M input tokens at $1 per million reads "$1.00"; the unknown model reads "unpriced".
        XCTAssertEqual(breakdown.models.first { $0.label == "claude/haiku-4-5" }?.costLabel, "$1.00")
        XCTAssertEqual(breakdown.models.first { $0.label == "codex/mystery-9" }?.costLabel, "unpriced")
        XCTAssertEqual(breakdown.costLine, "$1.00")
        XCTAssertEqual(breakdown.costDisclosure,
                       "at list prices, as of 2026-07-07 · 1.0K tokens unpriced")
    }

    /// Without a cost summary every cost surface stays off: no column labels, no line, no footnote.
    func testCostSurfacesAbsentWithoutASummary() {
        let breakdown = CognitionBreakdown.build(
            modelTotals: [model("claudeCode", "claude-haiku-4-5", input: 100, output: 100)],
            sessionStats: nil
        )
        XCTAssertNil(breakdown.models.first?.costLabel)
        XCTAssertNil(breakdown.costLine)
        XCTAssertNil(breakdown.costDisclosure)
    }

    /// A cache-only model is dropped from the bars but its cost still counts in the card's total.
    func testCacheOnlyModelStillCountsInTheCostLine() {
        let rows = [
            model("claudeCode", "claude-haiku-4-5", input: 0, output: 0, cache: 10_000_000),
            model("claudeCode", "claude-opus-4-8", input: 1_000_000, output: 0),
        ]
        let cost = PriceCard.bundled.cost(of: rows)
        let breakdown = CognitionBreakdown.build(modelTotals: rows, sessionStats: nil, cost: cost)
        XCTAssertEqual(breakdown.models.map(\.label), ["claude/opus-4-8"])
        // opus input $5.00 plus haiku cache 10M x ($1.25 write + $0.10 read) per million = $18.50.
        XCTAssertEqual(breakdown.costLine, "$18.50")
        XCTAssertEqual(breakdown.costDisclosure, "at list prices, as of 2026-07-07")
    }
}
