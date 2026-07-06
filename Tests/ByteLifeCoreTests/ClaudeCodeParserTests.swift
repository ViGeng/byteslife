import XCTest
@testable import ByteLifeCore

final class ClaudeCodeParserTests: XCTestCase {

    private func assistantLine(
        sessionId: String = "S1",
        requestId: String = "R1",
        messageId: String = "M1",
        uuid: String = "U1",
        timestamp: String? = "2026-07-06T12:00:00.000Z",
        usage: String = #"{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":2}"#
    ) -> String {
        let ts = timestamp.map { #""timestamp":"\#($0)","# } ?? ""
        return #"{"type":"assistant","sessionId":"\#(sessionId)","requestId":"\#(requestId)","uuid":"\#(uuid)",\#(ts)"message":{"id":"\#(messageId)","usage":\#(usage)}}"#
    }

    func testExtractsAllUsageFieldsAndDedupKey() {
        let event = ClaudeCodeParser.parse(line: assistantLine())
        XCTAssertNotNil(event)
        // Dedup key is exactly sessionId|message.id|requestId, uuid excluded.
        XCTAssertEqual(event?.dedupKey, "S1|M1|R1")
        XCTAssertEqual(event?.inputTokens, 100)
        XCTAssertEqual(event?.outputTokens, 10)
        XCTAssertEqual(event?.cacheCreationTokens, 5)
        XCTAssertEqual(event?.cacheReadTokens, 2)
    }

    func testUuidIsNotPartOfDedupKey() {
        let a = ClaudeCodeParser.parse(line: assistantLine(uuid: "UUID-A"))
        let b = ClaudeCodeParser.parse(line: assistantLine(uuid: "UUID-B"))
        // Same session/message/request, different uuid: identical dedup key so dedup can collapse them.
        XCTAssertEqual(a?.dedupKey, b?.dedupKey)
    }

    func testDedupKeyFallsBackToUuidWhenMessageIdAndRequestIdAbsent() {
        // A usage line with neither message.id nor requestId: distinct uuids must yield distinct keys
        // so they do not all collapse to one all-empty identity per session.
        let usage = #"{"input_tokens":1}"#
        let a = ClaudeCodeParser.parse(
            line: #"{"type":"assistant","sessionId":"S1","uuid":"UA","message":{"usage":\#(usage)}}"#
        )
        let b = ClaudeCodeParser.parse(
            line: #"{"type":"assistant","sessionId":"S1","uuid":"UB","message":{"usage":\#(usage)}}"#
        )
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a?.dedupKey, b?.dedupKey)
        // The same uuid still collapses, so a genuine re-read of one line dedups.
        let aAgain = ClaudeCodeParser.parse(
            line: #"{"type":"assistant","sessionId":"S1","uuid":"UA","message":{"usage":\#(usage)}}"#
        )
        XCTAssertEqual(a?.dedupKey, aAgain?.dedupKey)
    }

    func testDedupKeyUsesMessageAndRequestWhenEitherPresent() {
        // requestId alone (no message.id) still keys on the identity fields, not uuid.
        let a = ClaudeCodeParser.parse(
            line: #"{"type":"assistant","sessionId":"S1","requestId":"R9","uuid":"UA","message":{"usage":{"input_tokens":1}}}"#
        )
        let b = ClaudeCodeParser.parse(
            line: #"{"type":"assistant","sessionId":"S1","requestId":"R9","uuid":"UB","message":{"usage":{"input_tokens":1}}}"#
        )
        XCTAssertEqual(a?.dedupKey, b?.dedupKey)
    }

    func testMissingCacheFieldsDefaultToZero() {
        let line = assistantLine(usage: #"{"input_tokens":200,"output_tokens":20}"#)
        let event = ClaudeCodeParser.parse(line: line)
        XCTAssertEqual(event?.inputTokens, 200)
        XCTAssertEqual(event?.outputTokens, 20)
        XCTAssertEqual(event?.cacheCreationTokens, 0)
        XCTAssertEqual(event?.cacheReadTokens, 0)
    }

    func testParsesLineTimestamp() {
        let event = ClaudeCodeParser.parse(line: assistantLine())
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2026-07-06T12:00:00.000Z")
        XCTAssertEqual(event?.timestamp, expected)
    }

    func testFallsBackToNowWhenTimestampMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let event = ClaudeCodeParser.parse(line: assistantLine(timestamp: nil), now: now)
        XCTAssertEqual(event?.timestamp, now)
    }

    func testNonAssistantLineReturnsNil() {
        let line = #"{"type":"user","sessionId":"S1","message":{"role":"user","content":"hi"}}"#
        XCTAssertNil(ClaudeCodeParser.parse(line: line))
    }

    func testAssistantWithoutUsageReturnsNil() {
        let line = #"{"type":"assistant","sessionId":"S1","message":{"id":"M1","role":"assistant"}}"#
        XCTAssertNil(ClaudeCodeParser.parse(line: line))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(ClaudeCodeParser.parse(line: "{ this is not valid json"))
        XCTAssertNil(ClaudeCodeParser.parse(line: ""))
    }

    func testSamplesOmitsZeroChannels() {
        let event = ClaudeCodeParser.parse(line: assistantLine(usage: #"{"input_tokens":200,"output_tokens":20}"#))!
        let kinds = Set(event.samples().map { $0.kind })
        // Only the two non-zero channels produce samples.
        XCTAssertEqual(kinds, [.aiInputTokens, .aiOutputTokens])
    }
}
