import Foundation

/// One model on the COGNITION card's BY MODEL breakdown: a source-prefixed short label, its input+output
/// token total over the period, and its share of the busiest model (for the horizontal bar). The token
/// figure excludes cache, matching the Token Account's exchange-rate reasoning, so a model's bar reads the
/// tokens it actually prompted and generated.
public struct CognitionModelRow: Equatable, Sendable, Identifiable {
    /// The engraved label, e.g. "claude/opus-4-8".
    public let label: String
    /// Input + output tokens for this model over the period (cache excluded).
    public let tokens: Int64
    /// 0-1 against the busiest model's tokens, for the horizontal bar width.
    public let fraction: Double

    public var id: String { label }
    /// The token total, formatted compactly like the account headlines ("24.1K").
    public var tokenLabel: String { ByteFormatting.tokens(tokens) }

    public init(label: String, tokens: Int64, fraction: Double) {
        self.label = label
        self.tokens = tokens
        self.fraction = fraction
    }
}

/// The COGNITION card's fine-grained view: the day's (or period's) top models by prompted-and-generated
/// tokens, each with a proportional bar, and a one-line session memo. Shaped purely from the model ledger
/// rows and the session statistics, so every figure and label is covered by `swift test` with no store.
public struct CognitionBreakdown: Equatable, Sendable {
    /// The top models, heaviest first, capped by the caller's limit. Empty when no model was booked.
    public let models: [CognitionModelRow]
    /// The session memo, e.g. "7 sessions · avg 24m · longest 1h 12m", or nil when no session opened.
    public let sessionMemo: String?

    public init(models: [CognitionModelRow], sessionMemo: String?) {
        self.models = models
        self.sessionMemo = sessionMemo
    }

    /// Builds the breakdown from the model ledger totals (any order — the builder ranks and caps them) and
    /// the session statistics (nil for an aggregate period, which carries no session memo). Models are
    /// ranked by input+output tokens; a model that prompted and generated nothing (only cache traffic) is
    /// dropped, since it has no bar to draw. `limit` caps the top list.
    public static func build(
        modelTotals: [AIModelTotal],
        sessionStats: AISessionStats?,
        limit: Int = 5
    ) -> CognitionBreakdown {
        var ranked: [(label: String, tokens: Int64)] = []
        for row in modelTotals {
            let tokens = row.input + row.output
            guard tokens > 0 else { continue }
            ranked.append((label: shortLabel(source: row.source, model: row.model), tokens: tokens))
        }
        ranked.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.label < $1.label }

        let topTokens = ranked.first?.tokens ?? 0
        let models: [CognitionModelRow] = ranked.prefix(max(0, limit)).map { entry in
            CognitionModelRow(
                label: entry.label,
                tokens: entry.tokens,
                fraction: topTokens > 0 ? Double(entry.tokens) / Double(topTokens) : 0
            )
        }

        return CognitionBreakdown(models: models, sessionMemo: sessionMemo(sessionStats))
    }

    /// The session memo line: "N sessions · avg <len> · longest <len>", with the count singularized at one.
    /// Nil when no session opened (count zero) or when no statistics are supplied (aggregate periods).
    static func sessionMemo(_ stats: AISessionStats?) -> String? {
        guard let stats, stats.count > 0 else { return nil }
        let noun = stats.count == 1 ? "session" : "sessions"
        return "\(stats.count) \(noun) · avg \(ByteFormatting.duration(seconds: stats.averageLength))"
            + " · longest \(ByteFormatting.duration(seconds: stats.longestLength))"
    }

    /// A source-prefixed short label like "claude/opus-4-8": the source key shortened to its vendor and the
    /// model string with its redundant vendor prefix stripped, joined by a slash. Unknown vendors pass
    /// through unchanged, so a new source or model never loses information.
    static func shortLabel(source: String, model: String) -> String {
        "\(shortSource(source))/\(shortModel(model))"
    }

    /// The vendor form of a source key: "claudeCode" reads "claude"; "codex" and "gemini" already read as
    /// their vendor, and anything else passes through.
    private static func shortSource(_ source: String) -> String {
        switch source {
        case "claudeCode": return "claude"
        default: return source
        }
    }

    /// The model string with a redundant leading vendor token dropped ("claude-opus-4-8" -> "opus-4-8"),
    /// so the vendor is not repeated after the source prefix. An unrecognized model passes through.
    private static func shortModel(_ model: String) -> String {
        for prefix in ["claude-", "gpt-", "gemini-"] where model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        return model
    }
}
