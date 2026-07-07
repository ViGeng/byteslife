import Foundation

/// One `token_count` snapshot lifted from a Codex CLI `rollout-*.jsonl` line. Codex reports CUMULATIVE
/// per-session totals in `payload.info.total_token_usage`, so a snapshot is a running total, not a
/// delta; `CodexSource` subtracts successive snapshots per file to recover the per-event deltas.
public struct CodexTokenSnapshot: Equatable, Sendable {
    /// The event's own timestamp (falling back to "now" at parse time), so backfill lands in the right day.
    public let timestamp: Date
    /// Cumulative prompt tokens for the session so far.
    public let totalInput: Int64
    /// Cumulative generated tokens (already inclusive of reasoning output) for the session so far.
    public let totalOutput: Int64
    /// Cumulative cached-input tokens for the session so far.
    public let totalCached: Int64

    public init(timestamp: Date, totalInput: Int64, totalOutput: Int64, totalCached: Int64) {
        self.timestamp = timestamp
        self.totalInput = totalInput
        self.totalOutput = totalOutput
        self.totalCached = totalCached
    }
}

/// Parses a single line of a Codex CLI rollout transcript into an optional cumulative token snapshot.
public enum CodexParser {
    /// Returns a snapshot only for `type == "event_msg"` lines whose `payload.type == "token_count"`
    /// and whose `payload.info` is populated. A null `info` is a rate-limit heartbeat and returns nil;
    /// so do malformed JSON, other event types, and non-token_count payloads. `now` supplies the
    /// timestamp when the line has none.
    public static func parse(line: String, now: Date = Date()) -> CodexTokenSnapshot? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        guard root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count" else { return nil }

        // A null (or missing) `info` marks a rate-limit heartbeat that carries no usage; skip it.
        guard let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return nil }

        let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp) ?? now
        return CodexTokenSnapshot(
            timestamp: timestamp,
            totalInput: token(total, "input_tokens"),
            totalOutput: token(total, "output_tokens"),
            totalCached: token(total, "cached_input_tokens")
        )
    }

    /// Returns the model named by a `turn_context` line, or nil for any other line. Codex records the
    /// active model on each `turn_context` event (which precedes that turn's `token_count` events), so a
    /// tailing source tracks the latest model seen and attributes subsequent snapshots to it. A
    /// turn_context without a `model` field, and every non-turn_context line, return nil.
    public static func turnContextModel(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        guard root["type"] as? String == "turn_context",
              let payload = root["payload"] as? [String: Any] else { return nil }
        return payload["model"] as? String
    }

    private static func token(_ usage: [String: Any], _ key: String) -> Int64 {
        (usage[key] as? NSNumber)?.int64Value ?? 0
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        iso8601WithFraction.date(from: string) ?? iso8601Plain.date(from: string)
    }

    // Codex writes fractional-second ISO8601 ("...:21.696Z"); the plain formatter is a fallback.
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
