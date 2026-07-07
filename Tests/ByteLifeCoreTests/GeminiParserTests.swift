import XCTest
@testable import ByteLifeCore

final class GeminiParserTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testParsesPerTurnTokensFoldingThoughtsIntoOutput() {
        let json = """
        {"sessionId":"S","messages":[
          {"id":"m1","type":"gemini","timestamp":"2026-07-06T12:00:05.000Z","tokens":{"input":100,"output":10,"cached":5,"thoughts":3,"tool":0,"total":118}}
        ]}
        """
        let events = GeminiParser.parse(data: data(json))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.dedupKey, "gemini:S|m1")
        XCTAssertEqual(events.first?.inputTokens, 100)
        // output folds in the reasoning "thoughts" tokens: 10 + 3.
        XCTAssertEqual(events.first?.outputTokens, 13)
        XCTAssertEqual(events.first?.cacheReadTokens, 5)
    }

    func testSkipsMessagesWithoutTokens() {
        let json = """
        {"sessionId":"S","messages":[
          {"id":"u0","type":"user","content":"hi"},
          {"id":"m1","type":"gemini","tokens":{"input":1,"output":2,"cached":0,"thoughts":0,"tool":0,"total":3}}
        ]}
        """
        let events = GeminiParser.parse(data: data(json))
        XCTAssertEqual(events.map(\.dedupKey), ["gemini:S|m1"])
    }

    func testMalformedJSONReturnsEmpty() {
        XCTAssertTrue(GeminiParser.parse(data: data("{ not json")).isEmpty)
        XCTAssertTrue(GeminiParser.parse(data: Data()).isEmpty)
    }

    func testMissingMessagesArrayReturnsEmpty() {
        XCTAssertTrue(GeminiParser.parse(data: data(#"{"sessionId":"S"}"#)).isEmpty)
    }

    func testSamplesOmitZeroChannels() {
        let json = #"{"sessionId":"S","messages":[{"id":"m1","tokens":{"input":50,"output":0,"cached":0,"thoughts":0,"tool":0,"total":50}}]}"#
        let event = GeminiParser.parse(data: data(json)).first!
        XCTAssertEqual(Set(event.samples().map(\.kind)), [.aiInputTokens])
    }

    func testParsesTimestamp() {
        let json = #"{"sessionId":"S","messages":[{"id":"m1","timestamp":"2026-07-06T12:00:05.000Z","tokens":{"input":1,"output":0,"cached":0,"thoughts":0,"tool":0,"total":1}}]}"#
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(GeminiParser.parse(data: data(json)).first?.timestamp,
                       formatter.date(from: "2026-07-06T12:00:05.000Z"))
    }
}
