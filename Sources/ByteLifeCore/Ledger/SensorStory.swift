import Foundation

/// One curve on the Back Office SENSORS deck: a per-minute reading series for one gauge, its label, and a
/// short caption of the latest reading in the gauge's own unit. Gaps are honest — a minute with no reading
/// is `nil`, never a fabricated zero — so the chart breaks where the sensor was silent. Aggregate periods
/// carry no curves at all.
public struct SensorCurve: Equatable, Sendable, Identifiable {
    /// The stable gauge key (a `GaugeName`), used as identity and to pick the curve's tone.
    public let gauge: String
    /// The engraved title, e.g. "TEMPERATURE".
    public let label: String
    /// The day's 1440-slot minute series in the gauge's stored unit, `nil` where no reading was taken.
    public let points: [Int64?]
    /// The most recent reading formatted in the gauge's display unit, e.g. "42.5°C" / "87%", or nil when
    /// the gauge took no reading all day.
    public let latest: String?

    public var id: String { gauge }
    /// True when at least one minute carried a reading; a curve with none is not drawn.
    public var hasData: Bool { latest != nil }

    public init(gauge: String, label: String, points: [Int64?], latest: String?) {
        self.gauge = gauge
        self.label = label
        self.points = points
        self.latest = latest
    }
}

/// One count memo on the SENSORS deck: an engraved label and its grouped figure, in the same dry grammar
/// as the receipt's auxiliary lines. Booked but never reconciled.
public struct SensorMemo: Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let value: String

    public var id: String { key }

    public init(key: String, label: String, value: String) {
        self.key = key
        self.label = label
        self.value = value
    }
}

/// The Back Office SENSORS section shaped from a period's totals, the sensor deck's read-through meta
/// facts, and (single days only) the per-minute gauge series. It exposes the muted curve charts and the
/// count memos — lid opens, wakes, boots, audio switches, Bluetooth connects, volume changes, thermal
/// changes, battery cycles, and charging sessions. Aggregate periods pass no curves and their counts are
/// summed across the member days by the caller, so this model is fully covered by `swift test` with no I/O.
public struct SensorStory: Equatable, Sendable {
    /// The curve charts, in deck order; empty for an aggregate period.
    public let curves: [SensorCurve]
    /// The count memos, in deck order. Boots and battery cycles appear only when they carry a value.
    public let memos: [SensorMemo]

    public init(curves: [SensorCurve], memos: [SensorMemo]) {
        self.curves = curves
        self.memos = memos
    }

    /// The gauges the SENSORS curves read, in the order they are laid out, paired with their titles. One
    /// definition so the view fetches exactly these series and this model labels them identically.
    public static let curveGauges: [(gauge: String, label: String)] = [
        (GaugeName.cpuTemperature, "TEMPERATURE"),
        (GaugeName.batteryCharge, "CHARGE"),
        (GaugeName.ambientLux, "AMBIENT LIGHT"),
        (GaugeName.displayBrightness, "BRIGHTNESS"),
        (GaugeName.systemPowerWatts, "POWER"),
    ]

    /// Builds the story from a period's totals, the thermal-change and charging-session counts (summed
    /// across member days for an aggregate), the lifetime battery cycle count (nil when the battery never
    /// reported it), and an optional map of gauge -> minute series. A day passes its five series; an
    /// aggregate passes none, so `curves` comes back empty and only the memos print.
    public static func build(
        totals: [MetricKind: Int64],
        thermalStateChanges: Int64,
        chargingSessions: Int64,
        batteryCycleCount: Int64?,
        gaugeSeries: [String: [Int64?]] = [:]
    ) -> SensorStory {
        func t(_ k: MetricKind) -> Int64 { totals[k] ?? 0 }

        let curves: [SensorCurve] = gaugeSeries.isEmpty ? [] : curveGauges.map { entry in
            let points = gaugeSeries[entry.gauge] ?? []
            let last = points.compactMap { $0 }.last
            return SensorCurve(
                gauge: entry.gauge,
                label: entry.label,
                points: points,
                latest: last.map { reading(gauge: entry.gauge, value: $0) }
            )
        }

        var memos: [SensorMemo] = [
            SensorMemo(key: "lidOpens", label: "LID OPENS", value: ByteFormatting.grouped(t(.lidOpens))),
            SensorMemo(key: "wakes", label: "WAKES", value: ByteFormatting.grouped(t(.systemWakes))),
        ]
        // Boots appear only when a reboot was booked; a machine that stayed up all period skips the line.
        if t(.systemBoots) > 0 {
            memos.append(SensorMemo(key: "boots", label: "BOOTS", value: ByteFormatting.grouped(t(.systemBoots))))
        }
        memos += [
            SensorMemo(key: "audioSwitches", label: "AUDIO SWITCHES", value: ByteFormatting.grouped(t(.audioDeviceSwitches))),
            SensorMemo(key: "btConnects", label: "BT CONNECTS", value: ByteFormatting.grouped(t(.btConnects))),
            SensorMemo(key: "volumeChanges", label: "VOLUME CHANGES", value: ByteFormatting.grouped(t(.volumeChanges))),
            SensorMemo(key: "thermalChanges", label: "THERMAL CHANGES", value: ByteFormatting.grouped(max(0, thermalStateChanges))),
            SensorMemo(key: "chargingSessions", label: "CHARGING SESSIONS", value: ByteFormatting.grouped(max(0, chargingSessions))),
        ]
        // Battery cycles is a lifetime fact, printed only when the battery reported it.
        if let cycles = batteryCycleCount {
            memos.append(SensorMemo(key: "batteryCycles", label: "BATTERY CYCLES", value: ByteFormatting.grouped(cycles)))
        }

        return SensorStory(curves: curves, memos: memos)
    }

    /// Formats one gauge reading in its display unit for the curve caption: temperature and power to one
    /// decimal degree/watt, charge as a whole percent, brightness from per mille to a whole percent, and
    /// ambient light as a unitless level, because the sensor reports raw uncalibrated channel counts,
    /// not lux, and captioning them "lux" would overstate the precision.
    static func reading(gauge: String, value: Int64) -> String {
        switch gauge {
        case GaugeName.cpuTemperature:
            return String(format: "%.1f°C", Double(value) / 10)
        case GaugeName.batteryCharge:
            return "\(value)%"
        case GaugeName.ambientLux:
            return "level \(ByteFormatting.grouped(value))"
        case GaugeName.displayBrightness:
            return "\(Int((Double(value) / 10).rounded()))%"
        case GaugeName.systemPowerWatts:
            return String(format: "%.1f W", Double(value) / 10)
        default:
            return ByteFormatting.grouped(value)
        }
    }
}
