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
    /// The model's notional cost at list prices ("$1.23"), "unpriced" when no price matched (disclosed,
    /// never a silent zero), or nil when the breakdown was built without a cost summary (the cost column
    /// is then not rendered).
    public let costLabel: String?

    public var id: String { label }
    /// The token total, formatted compactly like the account headlines ("24.1K").
    public var tokenLabel: String { ByteFormatting.tokens(tokens) }

    public init(label: String, tokens: Int64, fraction: Double, costLabel: String? = nil) {
        self.label = label
        self.tokens = tokens
        self.fraction = fraction
        self.costLabel = costLabel
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
    /// The notional cost of every model booked over the period (not only the displayed top list), or nil
    /// when the caller supplied no summary (cost then stays off the card).
    public let cost: AICostSummary?

    public init(models: [CognitionModelRow], sessionMemo: String?, cost: AICostSummary? = nil) {
        self.models = models
        self.sessionMemo = sessionMemo
        self.cost = cost
    }

    /// The card's cost-line figure ("$12.34"), the priced total over the whole period.
    public var costLine: String? {
        cost.map { PriceCard.dollars($0.total) }
    }

    /// The footnote every cost surface carries once — the list-price framing with its as-of date — plus
    /// the unpriced disclosure when tokens were excluded from the total.
    public var costDisclosure: String? {
        guard let cost else { return nil }
        let framing = "at list prices, as of \(cost.asOf)"
        guard let unpriced = cost.unpricedDisclosure else { return framing }
        return "\(framing) · \(unpriced)"
    }

    /// Builds the breakdown from the model ledger totals (any order — the builder ranks and caps them),
    /// the session statistics (nil for an aggregate period, which carries no session memo), and the
    /// period's notional cost summary (nil keeps every cost surface off). Models are ranked by
    /// input+output tokens; a model that prompted and generated nothing (only cache traffic) is dropped,
    /// since it has no bar to draw — its cost still counts in the summary's total. `limit` caps the top
    /// list.
    public static func build(
        modelTotals: [AIModelTotal],
        sessionStats: AISessionStats?,
        limit: Int = 5,
        cost: AICostSummary? = nil
    ) -> CognitionBreakdown {
        // The summary's per-model cost lines keyed by source and model, so each displayed row can
        // carry its own cost figure.
        var costByKey: [String: AIModelCost] = [:]
        for line in cost?.models ?? [] { costByKey["\(line.source)|\(line.model)"] = line }
        func costLabel(source: String, model: String) -> String? {
            guard cost != nil else { return nil }
            guard let c = costByKey["\(source)|\(model)"]?.cost else { return "unpriced" }
            return PriceCard.dollars(c)
        }

        var ranked: [(label: String, tokens: Int64, costLabel: String?)] = []
        for row in modelTotals {
            // `uncachedInput` keeps the cache exclusion honest for sources that record cached tokens
            // inside the input channel (Codex, Gemini).
            let tokens = row.uncachedInput + row.output
            guard tokens > 0 else { continue }
            ranked.append((label: shortLabel(source: row.source, model: row.model), tokens: tokens,
                           costLabel: costLabel(source: row.source, model: row.model)))
        }
        ranked.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.label < $1.label }

        let topTokens = ranked.first?.tokens ?? 0
        let models: [CognitionModelRow] = ranked.prefix(max(0, limit)).map { entry in
            CognitionModelRow(
                label: entry.label,
                tokens: entry.tokens,
                fraction: topTokens > 0 ? Double(entry.tokens) / Double(topTokens) : 0,
                costLabel: entry.costLabel
            )
        }

        return CognitionBreakdown(models: models, sessionMemo: sessionMemo(sessionStats), cost: cost)
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
