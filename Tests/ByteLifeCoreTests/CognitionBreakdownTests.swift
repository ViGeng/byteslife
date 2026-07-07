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
}
