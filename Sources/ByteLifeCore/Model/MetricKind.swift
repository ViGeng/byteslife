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
    /// Mouse-button presses (left, right, or other) counted by the same listen-only tap.
    case inputClicks
    /// Accumulated absolute scroll-wheel travel in point units, counted by the same tap.
    case inputScrollUnits
    /// Screen unlocks, one per `com.apple.screenIsUnlocked`, an EXPOSURE memo counter.
    case screenUnlocks
    /// Attention sessions, incremented once each time attentiveness is (re)entered.
    case attentionSessions
    /// Energy drawn, stored as milliwatt-hours (additive deltas). Booked as watt-hours in the UI.
    case energyMilliwattHours
    /// File create/modify/rename events under the home directory, counted (never named).
    case filesTouched

    public var family: MetricFamily {
        switch self {
        case .networkBytesIn, .networkBytesOut:
            return .network
        case .diskBytesRead, .diskBytesWritten:
            return .disk
        case .aiInputTokens, .aiOutputTokens, .aiCacheCreationTokens, .aiCacheReadTokens:
            return .ai
        case .screenAttentiveSeconds, .screenUnlocks, .attentionSessions:
            return .screen
        case .inputKeystrokes, .inputMouseMilliPixels, .inputClicks, .inputScrollUnits:
            return .input
        case .energyMilliwattHours, .filesTouched:
            return .auxiliary
        }
    }
}
