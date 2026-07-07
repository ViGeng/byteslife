import Foundation

/// One app on the Focus Account's top list: its short display name, the time it held the foreground, and
/// its share of the busiest app's time (for the small horizontal bar). The fraction is against the top
/// app, so the leader's bar is always full and the rest read as proportions of it.
public struct AuxiliaryFocusApp: Equatable, Sendable, Identifiable {
    public let name: String
    public let seconds: Int64
    /// 0-1 against the busiest app's seconds, for the horizontal bar width.
    public let fraction: Double

    public var id: String { name }
    /// The time held, formatted like "1h 24m" / "45m".
    public var timeLabel: String { ByteFormatting.duration(seconds: seconds) }

    public init(name: String, seconds: Int64, fraction: Double) {
        self.name = name
        self.seconds = seconds
        self.fraction = fraction
    }
}

/// The accessory accounts on the Back Office day (or aggregate) story: the Energy Account with its
/// per-hour bars, the Focus Account's top apps, files touched, hosts contacted, and the EXPOSURE session
/// and unlock memos. Booked but never reconciled, these sit alongside the five ledger accounts as figure
/// cards. Shaped purely from a totals dictionary, the ranked focus rows, the distinct-host count, and an
/// optional energy hourly series, so every figure is covered by `swift test` with no clock or I/O.
public struct AuxiliaryStory: Equatable, Sendable {
    /// Energy drawn over the period, formatted in watt-hours.
    public let energyHeadline: String
    /// True when energy was booked at all; false shows the account as unopened.
    public let energyPresent: Bool
    /// Energy per hour (milliwatt-hours) for the account's bars, empty when not fetched (aggregates).
    public let energyHourly: [Int64]
    /// The top focused apps, longest first, capped by the caller's limit.
    public let focusApps: [AuxiliaryFocusApp]
    /// File create/modify events counted over the period.
    public let filesTouched: Int64
    public let filesPresent: Bool
    /// Distinct remote hosts contacted; nil when the hosts sensor is unavailable.
    public let distinctHosts: Int?
    /// Screen unlocks over the period.
    public let unlocks: Int64
    /// Attention sessions over the period.
    public let sessions: Int64

    public init(energyHeadline: String, energyPresent: Bool, energyHourly: [Int64],
                focusApps: [AuxiliaryFocusApp], filesTouched: Int64, filesPresent: Bool,
                distinctHosts: Int?, unlocks: Int64, sessions: Int64) {
        self.energyHeadline = energyHeadline
        self.energyPresent = energyPresent
        self.energyHourly = energyHourly
        self.focusApps = focusApps
        self.filesTouched = filesTouched
        self.filesPresent = filesPresent
        self.distinctHosts = distinctHosts
        self.unlocks = unlocks
        self.sessions = sessions
    }

    /// Builds the story from a period's totals (one day's or an aggregate's summed totals), the ranked
    /// focus rows (bundle id and seconds, in any order — the builder ranks and caps them), the distinct
    /// host count (nil when unavailable), and an optional energy hourly series. `focusLimit` caps the top
    /// list (five for the day and aggregate cards). Bundle ids collapse to short display names, and rows
    /// that share a short name are merged so one app never appears twice.
    public static func build(
        totals: [MetricKind: Int64],
        focus: [(bundleId: String, seconds: Int64)],
        distinctHosts: Int?,
        energyHourly: [Int64] = [],
        focusLimit: Int = 5
    ) -> AuxiliaryStory {
        // Merge rows by short display name so, e.g., two bundle ids that both render "Safari" combine.
        var byName: [String: Int64] = [:]
        for row in focus where row.seconds > 0 {
            byName[AppShortName.short(bundleID: row.bundleId), default: 0] += row.seconds
        }
        let ranked = byName.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let topSeconds = ranked.first?.value ?? 0
        let focusApps = ranked.prefix(max(0, focusLimit)).map { entry in
            AuxiliaryFocusApp(
                name: entry.key,
                seconds: entry.value,
                fraction: topSeconds > 0 ? Double(entry.value) / Double(topSeconds) : 0
            )
        }

        let energy = totals[.energyMilliwattHours]
        return AuxiliaryStory(
            energyHeadline: ByteFormatting.wattHours(milliwattHours: energy ?? 0),
            energyPresent: energy != nil,
            energyHourly: energyHourly,
            focusApps: Array(focusApps),
            filesTouched: totals[.filesTouched] ?? 0,
            filesPresent: totals[.filesTouched] != nil,
            distinctHosts: distinctHosts,
            unlocks: totals[.screenUnlocks] ?? 0,
            sessions: totals[.attentionSessions] ?? 0
        )
    }
}
