import Foundation

/// One chip on the panel's ALSO ON THE BOOKS strip: a small engraved label, its formatted figure, and
/// whether the underlying sensor reported at all. A chip that is `absent` renders as an honest dim dash
/// rather than a fabricated zero, so a missing or off sensor never masquerades as a real reading.
public struct AuxiliaryChip: Equatable, Sendable, Identifiable {
    public let key: String
    /// The engraved label, e.g. "ENERGY", "FOCUS", "FILES", "HOSTS", "UNLOCKS".
    public let label: String
    /// The formatted figure, or the dim dash when the sensor did not report.
    public let value: String
    /// False when the sensor is off or missing; the view renders the value dim in that case.
    public let present: Bool

    public var id: String { key }

    public init(key: String, label: String, value: String, present: Bool) {
        self.key = key
        self.label = label
        self.value = value
        self.present = present
    }
}

/// The compact figures-only strip that sits above the reconcile bar: energy today, the top app and its
/// time, files touched, distinct hosts, and unlocks. No charts, no rates — just the day's accessory
/// figures in the panel's dry grammar. Shaped purely from the day's totals, the single top-focus app, and
/// the distinct-host count, so every figure and every dash decision is covered by `swift test` with no
/// clock, locale, or I/O of its own.
public struct AuxiliaryStrip: Equatable, Sendable {
    public let chips: [AuxiliaryChip]

    /// The dim dash a sensor that did not report shows in place of a figure.
    public static let dash = "—"

    public init(chips: [AuxiliaryChip]) {
        self.chips = chips
    }

    /// Builds the strip from the day's totals, the single most-focused app (nil when none is on file), the
    /// distinct-host count (nil when the hosts sensor is unavailable), and each remaining sensor's running
    /// state. Presence now follows the sensor, not the datum: a running sensor that booked nothing reads a
    /// genuine 0, and only an off or missing sensor reads the dim dash, so an idle sensor never
    /// masquerades as an absent one. The hosts sensor keeps carrying its own absence as `distinctHosts`
    /// nil, which the caller already sets from the same availability check.
    public static func build(
        totals: [MetricKind: Int64],
        topFocus: (bundleId: String, seconds: Int64)?,
        distinctHosts: Int?,
        energyRunning: Bool,
        focusRunning: Bool,
        filesRunning: Bool,
        unlocksRunning: Bool
    ) -> AuxiliaryStrip {
        var chips: [AuxiliaryChip] = []

        // Energy: booked in mWh, surfaced in Wh. A running meter that has drawn nothing yet reads 0 Wh;
        // only an off or missing meter shows the dim dash.
        if energyRunning {
            chips.append(AuxiliaryChip(key: "energy", label: "ENERGY",
                                       value: ByteFormatting.wattHours(milliwattHours: totals[.energyMilliwattHours] ?? 0),
                                       present: true))
        } else {
            chips.append(AuxiliaryChip(key: "energy", label: "ENERGY", value: dash, present: false))
        }

        // Focus: the busiest app's short name and its time. Present while the sensor runs; a running
        // sensor with no foreground app yet still reads present (a placeholder dash in normal ink), never
        // the dim off-sensor dash.
        if focusRunning {
            if let focus = topFocus, focus.seconds > 0 {
                let name = AppShortName.short(bundleID: focus.bundleId)
                chips.append(AuxiliaryChip(key: "focus", label: "FOCUS",
                                           value: "\(name) \(ByteFormatting.duration(seconds: focus.seconds))",
                                           present: true))
            } else {
                chips.append(AuxiliaryChip(key: "focus", label: "FOCUS", value: dash, present: true))
            }
        } else {
            chips.append(AuxiliaryChip(key: "focus", label: "FOCUS", value: dash, present: false))
        }

        chips.append(countChip(key: "files", label: "FILES", totals: totals, kind: .filesTouched, running: filesRunning))

        if let hosts = distinctHosts {
            chips.append(AuxiliaryChip(key: "hosts", label: "HOSTS",
                                       value: ByteFormatting.grouped(Int64(hosts)), present: true))
        } else {
            chips.append(AuxiliaryChip(key: "hosts", label: "HOSTS", value: dash, present: false))
        }

        chips.append(countChip(key: "unlocks", label: "UNLOCKS", totals: totals, kind: .screenUnlocks, running: unlocksRunning))

        return AuxiliaryStrip(chips: chips)
    }

    /// A grouped-integer chip present whenever its sensor is running: a running sensor that booked nothing
    /// shows a genuine 0, and only an off or missing sensor shows the dim dash.
    private static func countChip(key: String, label: String,
                                  totals: [MetricKind: Int64], kind: MetricKind, running: Bool) -> AuxiliaryChip {
        guard running else { return AuxiliaryChip(key: key, label: label, value: dash, present: false) }
        return AuxiliaryChip(key: key, label: label, value: ByteFormatting.grouped(totals[kind] ?? 0), present: true)
    }
}
