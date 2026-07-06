/// A single measurable channel. Raw values are stable SQLite keys and must never change.
public enum MetricKind: String, CaseIterable, Sendable {
    case networkBytesIn
    case networkBytesOut
    case diskBytesRead
    case diskBytesWritten
    case aiInputTokens
    case aiOutputTokens
    case aiCacheCreationTokens
    case aiCacheReadTokens
    case screenAttentiveSeconds
    case inputKeystrokes
    /// Mouse travel distance stored as milli-pixels (pixels * 1000) so it fits an Int64 counter.
    case inputMouseMilliPixels

    public var family: MetricFamily {
        switch self {
        case .networkBytesIn, .networkBytesOut:
            return .network
        case .diskBytesRead, .diskBytesWritten:
            return .disk
        case .aiInputTokens, .aiOutputTokens, .aiCacheCreationTokens, .aiCacheReadTokens:
            return .ai
        case .screenAttentiveSeconds:
            return .screen
        case .inputKeystrokes, .inputMouseMilliPixels:
            return .input
        }
    }
}
