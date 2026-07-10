import Foundation

/// USD list prices per MILLION tokens for one model, one rate per token channel.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    /// The cache-write (cache-creation) rate. Anthropic publishes a distinct write price (the 5-minute
    /// tier at 1.25x input). OpenAI and Google publish none: their caching bills writes as ordinary
    /// input, and indeed the Codex and Gemini sources never book a cache-creation channel at all (Codex
    /// maps `cached_input_tokens` to cache READS), so for those providers this rate equals the input
    /// rate and prices a channel that is zero in practice.
    public let cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// One model's notional cost line. `cost` is nil when no price matched: the model is UNPRICED and its
/// tokens are excluded from the total and disclosed, never silently valued at zero.
public struct AIModelCost: Equatable, Sendable {
    public let source: String
    public let model: String
    /// Every token channel counted once (`AIModelTotal.total`), the figure disclosed when the model
    /// is unpriced.
    public let tokens: Int64
    /// Notional USD cost at list prices, or nil for an unpriced model.
    public let cost: Double?

    public init(source: String, model: String, tokens: Int64, cost: Double?) {
        self.source = source
        self.model = model
        self.tokens = tokens
        self.cost = cost
    }
}

/// The notional cost of a set of model-ledger rows, carrying everything the "at list prices, as of"
/// framing needs: per-model lines, the priced total, the excluded token count, and the card's date.
public struct AICostSummary: Equatable, Sendable {
    /// The price card's as-of date ("2026-07-07"), so every surface can print its framing.
    public let asOf: String
    /// One line per (source, model) row, priced rows first (costliest leading), unpriced rows last.
    public let models: [AIModelCost]
    /// The USD total over priced models only.
    public let total: Double
    /// Tokens (all channels) belonging to unpriced models, excluded from `total`.
    public let unpricedTokens: Int64

    public init(asOf: String, models: [AIModelCost], total: Double, unpricedTokens: Int64) {
        self.asOf = asOf
        self.models = models
        self.total = total
        self.unpricedTokens = unpricedTokens
    }

    /// The disclosure line for excluded tokens, e.g. "2.1K tokens unpriced", or nil when none were.
    public var unpricedDisclosure: String? {
        unpricedTokens > 0 ? "\(ByteFormatting.tokens(unpricedTokens)) tokens unpriced" : nil
    }

    /// Priced before unpriced, then costliest, then heaviest, then source+model as a stable tiebreak.
    static func displayOrder(_ a: AIModelCost, _ b: AIModelCost) -> Bool {
        switch (a.cost, b.cost) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return (a.source, a.model) < (b.source, b.model)
        }
    }
}

/// The bundled list-price card: official pay-as-you-go API prices in USD per million tokens, verified
/// as of `asOf` and refreshed at release time by the maintainer. The app is networkless, so this card
/// is the only price source, and every figure it produces is a VALUATION at list prices, not a bill.
/// The Gemini prices are the sub-200k-context tier; the long-context uplift is deliberately ignored in
/// v1 and disclosed in the plan.
public struct PriceCard: Sendable {
    public let asOf: String
    /// Normalized model-name key to price. A key matches any stored model string it prefixes.
    private let prices: [String: ModelPrice]

    public init(asOf: String, prices: [String: ModelPrice]) {
        self.asOf = asOf
        self.prices = Dictionary(uniqueKeysWithValues: prices.map { (Self.normalize($0.key), $0.value) })
    }

    public static let bundled = PriceCard(asOf: "2026-07-07", prices: [
        // Anthropic: cache write is the 5-minute tier at 1.25x input; cache read is 0.1x input.
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1.00, cacheWrite: 12.50),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25),
        // OpenAI: cached input reads at 10 percent of input; writes bill as ordinary input (see
        // ModelPrice.cacheWrite), and Codex books no cache-creation channel anyway.
        "gpt-5.3-codex": ModelPrice(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 1.75),
        "gpt-5.2-codex": ModelPrice(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 1.75),
        "gpt-5.4": ModelPrice(input: 2.50, output: 15.00, cacheRead: 0.25, cacheWrite: 2.50),
        "gpt-5.4-mini": ModelPrice(input: 0.75, output: 4.50, cacheRead: 0.075, cacheWrite: 0.75),
        // Google: sub-200k tier; no separate write price, same reasoning as OpenAI.
        "gemini-3-pro-preview": ModelPrice(input: 2.00, output: 12.00, cacheRead: 0.20, cacheWrite: 2.00),
        "gemini-3-flash-preview": ModelPrice(input: 0.50, output: 3.00, cacheRead: 0.05, cacheWrite: 0.50),
    ])

    // MARK: - Matching

    /// Lowercased and trimmed, with a Gemini-API-style "models/" prefix dropped. The sources store
    /// model names verbatim from the transcripts ("claude-opus-4-6-20260115", "gpt-5.4-codex",
    /// "gemini-2.5-pro"), so this is all the normalization real data needs.
    static func normalize(_ model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("models/") { name.removeFirst("models/".count) }
        return name
    }

    /// Longest-prefix match on the normalized model string, so dated or suffixed variants
    /// ("claude-opus-4-6-20260115") price as their base model. A key only matches up to a name
    /// boundary: the character after the prefix must be non-alphanumeric, so "gpt-5.4" prices
    /// "gpt-5.4-mini" via the longer key but never claims a hypothetical "gpt-5.41". No match
    /// returns nil, which books the model as unpriced.
    public func price(forModel model: String) -> ModelPrice? {
        let name = Self.normalize(model)
        var best: (key: String, price: ModelPrice)?
        for (key, price) in prices {
            guard name.hasPrefix(key) else { continue }
            let rest = name.dropFirst(key.count)
            if let next = rest.first, next.isLetter || next.isNumber { continue }
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        return best?.price
    }

    // MARK: - Costing

    /// Prices a set of model-ledger rows (one day's `aiModelTotals`, or a period's pre-summed rows).
    /// Cost per row is uncachedInput*in + output*out + cacheRead*read + cacheCreation*write, per million,
    /// in Double: this is a display valuation, not billing, and Int64 micro-dollar products would overflow
    /// at real cache volumes. `uncachedInput` matters: Codex and Gemini record cached tokens INSIDE the
    /// input channel (see `AIModelTotal.cacheInclusiveInputSources`), so billing raw input plus cacheRead
    /// would charge cached context at 110 percent of the input rate instead of the honest cache-read
    /// rate. Unmatched rows book as unpriced: excluded from the total, disclosed by token count.
    public func cost(of rows: [AIModelTotal]) -> AICostSummary {
        var models: [AIModelCost] = []
        var total = 0.0
        var unpriced: Int64 = 0
        for row in rows {
            if let price = price(forModel: row.model) {
                let cost = (Double(row.uncachedInput) * price.input
                    + Double(row.output) * price.output
                    + Double(row.cacheRead) * price.cacheRead
                    + Double(row.cacheCreation) * price.cacheWrite) / 1_000_000
                total += cost
                models.append(AIModelCost(source: row.source, model: row.model, tokens: row.total, cost: cost))
            } else {
                unpriced += row.total
                models.append(AIModelCost(source: row.source, model: row.model, tokens: row.total, cost: nil))
            }
        }
        models.sort(by: AICostSummary.displayOrder)
        return AICostSummary(asOf: asOf, models: models, total: total, unpricedTokens: unpriced)
    }

    // MARK: - Formatting

    /// Formats a notional USD amount deterministically (no locale): "$0.00", "<$0.01" for a positive
    /// sub-cent amount (never rounded down to a dishonest zero), else grouped dollars with two decimals
    /// ("$1,234.56").
    public static func dollars(_ amount: Double) -> String {
        guard amount > 0 else { return "$0.00" }
        let cents = Int64((amount * 100).rounded())
        guard cents > 0 else { return "<$0.01" }
        return "$\(ByteFormatting.grouped(cents / 100)).\(String(format: "%02lld", cents % 100))"
    }
}
