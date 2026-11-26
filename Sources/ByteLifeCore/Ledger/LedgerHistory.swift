import Foundation

public enum LedgerModule: String, CaseIterable, Identifiable, Sendable {
    case traffic = "Traffic"
    case storage = "Storage"
    case cognition = "Cognition"
    case mechanics = "Mechanics"
    case exposure = "Exposure"
    case other = "Other"

    public var id: Self { self }

    public var account: LedgerAccountKind? {
        switch self {
        case .traffic: return .traffic
        case .storage: return .storage
        case .cognition: return .token
        case .mechanics: return .labor
        case .exposure: return .hours
        case .other: return nil
        }
    }

    public var metrics: [LedgerHistoryMetric] {
        switch self {
        case .traffic:
            return [
                .init("Total traffic", DayStory.kinds(for: .traffic), .bytes),
                .init("Received", [.networkBytesIn], .bytes),
                .init("Sent", [.networkBytesOut], .bytes),
            ]
        case .storage:
            return [
                .init("Total disk activity", DayStory.kinds(for: .storage), .bytes),
                .init("Read", [.diskBytesRead], .bytes),
                .init("Written", [.diskBytesWritten], .bytes),
            ]
        case .cognition:
            return [
                .init("Total tokens", DayStory.kinds(for: .token), .tokens),
                .init("Prompted", [.aiInputTokens], .tokens),
                .init("Generated", [.aiOutputTokens], .tokens),
                .init("Cache reads", [.aiCacheReadTokens], .tokens),
                .init("Cache writes", [.aiCacheCreationTokens], .tokens),
            ]
        case .mechanics:
            return [
                .init("Keystrokes", [.inputKeystrokes]),
                .init("Clicks", [.inputClicks]),
                .init("Scroll travel", [.inputScrollUnits], .points),
                .init("Mouse travel", [.inputMouseMilliPixels], .distance),
            ]
        case .exposure:
            return [
                .init("Attentive time", [.screenAttentiveSeconds], .duration),
                .init("Attention sessions", [.attentionSessions]),
                .init("Unlocks", [.screenUnlocks]),
            ]
        case .other:
            return [
                .init("Energy", [.energyMilliwattHours], .energy),
                .init("Files touched", [.filesTouched]),
                .init("Terminal commands", [.commandsRun]),
                .init("Lid opens", [.lidOpens]),
                .init("Wakes", [.systemWakes]),
                .init("Boots", [.systemBoots]),
                .init("Audio device switches", [.audioDeviceSwitches]),
                .init("Bluetooth connects", [.btConnects]),
                .init("Volume changes", [.volumeChanges]),
            ]
        }
    }
}

public struct LedgerHistoryMetric: Hashable, Sendable, Identifiable {
    enum Unit: Hashable {
        case count, bytes, tokens, duration, distance, energy, points
    }

    public let label: String
    private let kinds: [MetricKind]
    private let unit: Unit
    public var id: String { label }

    init(_ label: String, _ kinds: [MetricKind], _ unit: Unit = .count) {
        self.label = label
        self.kinds = kinds
        self.unit = unit
    }

    /// A missing rollup leaves a gap even when a different metric recorded data that day.
    public func value(in totals: [MetricKind: Int64]) -> Int64? {
        let values = kinds.compactMap { totals[$0] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public func formatted(_ value: Int64) -> String {
        switch unit {
        case .count: return ByteFormatting.grouped(value)
        case .bytes: return ByteFormatting.bytes(value)
        case .tokens: return "\(ByteFormatting.tokens(value)) tok"
        case .duration: return ByteFormatting.duration(seconds: value)
        case .distance: return ByteFormatting.distanceHauled(milliPixels: value)
        case .energy: return ByteFormatting.wattHours(milliwattHours: value)
        case .points: return "\(ByteFormatting.grouped(value)) pt"
        }
    }
}

public struct LedgerHistory {
    public struct Day: Equatable, Identifiable {
        public let dayEpoch: Int64
        public let value: Int64?
        public var id: Int64 { dayEpoch }
    }

    public let days: [Day]
    /// Monday-first columns with empty slots outside the requested date range.
    public let weeks: [[Day?]]

    public init(
        metric: LedgerHistoryMetric,
        dayCount: Int,
        ending end: Date,
        totalsByDay: [Int64: [MetricKind: Int64]],
        calendar: Calendar = .current
    ) {
        let end = calendar.startOfDay(for: end)
        let dates = (0..<max(0, dayCount)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: end)
        }
        let days = dates.map { date in
            let epoch = DayBucket.dayEpoch(for: date, calendar: calendar)
            return Day(dayEpoch: epoch, value: metric.value(in: totalsByDay[epoch] ?? [:]))
        }
        self.days = days
        guard let first = dates.first else {
            weeks = []
            return
        }
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        var slots = Array<Day?>(repeating: nil, count: leading)
        slots.append(contentsOf: days.map(Optional.some))
        slots.append(contentsOf: Array(repeating: nil, count: (7 - slots.count % 7) % 7))
        weeks = stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<($0 + 7)]) }
    }
}
