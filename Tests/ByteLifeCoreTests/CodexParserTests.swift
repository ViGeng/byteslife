import XCTest
@testable import ByteLifeCore

final class CodexParserTests: XCTestCase {

    private func tokenCountLine(
        input: Int = 100,
        cached: Int = 5,
        output: Int = 10,
        reasoning: Int = 0,
        timestamp: String? = "2026-07-06T12:00:00.000Z"
    ) -> String {
        let ts = timestamp.map { #""timestamp":"\#($0)","# } ?? ""
        let total = input + output
        return #"{"type":"event_msg",\#(ts)"payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)}}}}"#
    }

    func testExtractsCumulativeTotals() {
        let snapshot = CodexParser.parse(line: tokenCountLine(input: 300, cached: 20, output: 40))
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.totalInput, 300)
        XCTAssertEqual(snapshot?.totalCached, 20)
        XCTAssertEqual(snapshot?.totalOutput, 40)
    }

    func testNullInfoReturnsNil() {
        let line = #"{"type":"event_msg","timestamp":"2026-07-06T12:00:00.000Z","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":1.0}}}}"#
        XCTAssertNil(CodexParser.parse(line: line))
    }

    func testMissingInfoReturnsNil() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}"#
        XCTAssertNil(CodexParser.parse(line: line))
    }

    func testNonTokenCountEventReturnsNil() {
        let line = #"{"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#
        XCTAssertNil(CodexParser.parse(line: line))
    }

    func testNonEventMsgReturnsNil() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant"}}"#
        XCTAssertNil(CodexParser.parse(line: line))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(CodexParser.parse(line: "{ not json"))
        XCTAssertNil(CodexParser.parse(line: ""))
    }

    func testTurnContextModelExtractsModel() {
        let line = #"{"type":"turn_context","timestamp":"2026-07-06T12:00:00.000Z","payload":{"turn_id":"t1","cwd":"/w","model":"gpt-5.4-codex","effort":"high"}}"#
        XCTAssertEqual(CodexParser.turnContextModel(line: line), "gpt-5.4-codex")
    }

    func testTurnContextModelNilForNonTurnContextOrModelless() {
        // A token_count line, a turn_context without a model, and malformed JSON all yield nil.
        XCTAssertNil(CodexParser.turnContextModel(line: tokenCountLine()))
        XCTAssertNil(CodexParser.turnContextModel(line: #"{"type":"turn_context","payload":{"cwd":"/w"}}"#))
        XCTAssertNil(CodexParser.turnContextModel(line: "{ not json"))
    }

    func testParsesTimestamp() {
        let snapshot = CodexParser.parse(line: tokenCountLine())
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(snapshot?.timestamp, formatter.date(from: "2026-07-06T12:00:00.000Z"))
    }

    func testFallsBackToNowWhenTimestampMissing() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = CodexParser.parse(line: tokenCountLine(timestamp: nil), now: now)
        XCTAssertEqual(snapshot?.timestamp, now)
    }
}
