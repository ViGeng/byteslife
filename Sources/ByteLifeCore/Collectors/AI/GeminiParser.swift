import Foundation

/// One usage-bearing message lifted from a Gemini CLI chat session file. Unlike Codex, Gemini records
/// PER-TURN token counts on each assistant message (not cumulative), so a snapshot is already the
/// delta and no successive subtraction is needed.
public struct GeminiUsageEvent: Equatable, Sendable {
    /// The dedup identity: the session id and the message's own stable id, joined with "|". Because
    /// Gemini rewrites the whole session file in place, this content identity (not a byte offset) is
    /// what keeps a re-read from double-counting.
    public let dedupKey: String
    /// The message's own timestamp (falling back to "now" at parse time), so backfill lands in the
    /// right day bucket.
    public let timestamp: Date
    /// The answering model from the message's `model` field, or "unknown" when it carried none.
    public let model: String
    /// The session this message belongs to, from the file's top-level `sessionId` (empty when absent).
    public let sessionId: String
    public let inputTokens: Int64
    /// Generated tokens plus reasoning ("thoughts") tokens, folded together so the output channel
    /// captures the full cognition the same way Codex's `output_tokens` already includes reasoning.
    public let outputTokens: Int64
    public let cacheReadTokens: Int64

    public init(dedupKey: String, timestamp: Date, model: String = "unknown", sessionId: String = "",
                inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64) {
        self.dedupKey = dedupKey
        self.timestamp = timestamp
        self.model = model
        self.sessionId = sessionId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// The additive samples this event contributes, one per non-zero token channel.
    public func samples() -> [Sample] {
        var out: [Sample] = []
        if inputTokens != 0 { out.append(Sample(kind: .aiInputTokens, value: inputTokens, timestamp: timestamp)) }
        if outputTokens != 0 { out.append(Sample(kind: .aiOutputTokens, value: outputTokens, timestamp: timestamp)) }
        if cacheReadTokens != 0 { out.append(Sample(kind: .aiCacheReadTokens, value: cacheReadTokens, timestamp: timestamp)) }
        return out
    }
}

/// Parses a Gemini CLI chat session file (`~/.gemini/tmp/<hash>/chats/session-*.json`) into its
/// usage-bearing messages.
public enum GeminiParser {
    /// Returns one event per message that carries a `tokens` object, keyed by session id and message
    /// id. Malformed JSON, a file with no `messages` array, and messages without token counts all yield
    /// no events rather than throwing. `now` supplies the timestamp when a message has none.
    ///
    /// The Gemini CLI's per-project `logs.json` carries no token counts on this machine, so only the
    /// chat session files are parsed; a file that lacks the expected token shape simply produces nothing,
    /// which the source surfaces honestly rather than fabricating counts.
    public static func parse(data: Data, now: Date = Date()) -> [GeminiUsageEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return [] }

        let sessionId = root["sessionId"] as? String ?? ""
        var events: [GeminiUsageEvent] = []
        for message in messages {
            guard let tokens = message["tokens"] as? [String: Any] else { continue }
            let messageId = message["id"] as? String ?? ""
            let model = message["model"] as? String ?? "unknown"
            let timestamp = (message["timestamp"] as? String).flatMap(parseTimestamp) ?? now
            events.append(GeminiUsageEvent(
                dedupKey: "gemini:\(sessionId)|\(messageId)",
                timestamp: timestamp,
                model: model,
                sessionId: sessionId,
                inputTokens: token(tokens, "input"),
                outputTokens: token(tokens, "output") + token(tokens, "thoughts"),
                cacheReadTokens: token(tokens, "cached")
            ))
        }
        return events
    }

    private static func token(_ tokens: [String: Any], _ key: String) -> Int64 {
        (tokens[key] as? NSNumber)?.int64Value ?? 0
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        iso8601WithFraction.date(from: string) ?? iso8601Plain.date(from: string)
    }

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
