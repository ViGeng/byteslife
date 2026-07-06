import Foundation

/// One usage-bearing record extracted from a Claude Code JSONL assistant line.
public struct AIUsageEvent: Equatable, Sendable {
    /// The exact dedup identity: `sessionId`, `message.id`, and top-level `requestId` joined with
    /// "|". The per-line `uuid` is deliberately excluded: it is unique on every line, so keying on it
    /// would defeat dedup, and Claude Code emits byte-identical usage lines that differ only in uuid.
    public let dedupKey: String
    /// The record's own timestamp (falling back to "now" at parse time), so historical backfill lands
    /// in the correct day bucket.
    public let timestamp: Date
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationTokens: Int64
    public let cacheReadTokens: Int64

    public init(
        dedupKey: String,
        timestamp: Date,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheCreationTokens: Int64,
        cacheReadTokens: Int64
    ) {
        self.dedupKey = dedupKey
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// The additive samples this event contributes, one per non-zero token channel.
    public func samples() -> [Sample] {
        var out: [Sample] = []
        func add(_ kind: MetricKind, _ value: Int64) {
            if value != 0 { out.append(Sample(kind: kind, value: value, timestamp: timestamp)) }
        }
        add(.aiInputTokens, inputTokens)
        add(.aiOutputTokens, outputTokens)
        add(.aiCacheCreationTokens, cacheCreationTokens)
        add(.aiCacheReadTokens, cacheReadTokens)
        return out
    }
}

/// Parses a single line of a Claude Code JSONL transcript into an optional usage event.
public enum ClaudeCodeParser {
    /// Returns an event only for `type == "assistant"` lines that carry `message.usage`. Malformed
    /// JSON, non-assistant lines, and assistant lines without usage all return nil rather than throw.
    /// `now` supplies the timestamp when the line has none.
    public static func parse(line: String, now: Date = Date()) -> AIUsageEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        guard root["type"] as? String == "assistant" else { return nil }
        guard let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }

        let sessionId = root["sessionId"] as? String ?? ""
        let requestId = root["requestId"] as? String ?? ""
        let messageId = message["id"] as? String ?? ""
        let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp) ?? now

        // Normally the identity is message.id plus requestId. When a line carries neither, those
        // fields would both be empty and every such line in a session would collapse to one key, so
        // fall back to the per-line `uuid` (unique per line) to keep distinct events distinct.
        let identity = (messageId.isEmpty && requestId.isEmpty)
            ? "uuid:\(root["uuid"] as? String ?? "")"
            : "\(messageId)|\(requestId)"

        return AIUsageEvent(
            dedupKey: "\(sessionId)|\(identity)",
            timestamp: timestamp,
            inputTokens: token(usage, "input_tokens"),
            outputTokens: token(usage, "output_tokens"),
            cacheCreationTokens: token(usage, "cache_creation_input_tokens"),
            cacheReadTokens: token(usage, "cache_read_input_tokens")
        )
    }

    private static func token(_ usage: [String: Any], _ key: String) -> Int64 {
        // JSONSerialization decodes every JSON number as NSNumber; a missing key defaults to 0.
        (usage[key] as? NSNumber)?.int64Value ?? 0
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        iso8601WithFraction.date(from: string) ?? iso8601Plain.date(from: string)
    }

    // Claude Code writes fractional-second ISO8601 ("...:41.900Z"); the plain formatter is a fallback.
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
