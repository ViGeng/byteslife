import Foundation

/// The stable `gauges.gauge` keys for the per-minute sensor curves. Defined once so the collectors that
/// write them and any surface that reads them can never disagree on a name (the primary key is the name).
/// Values are stored as integers in the units noted, because a gauge is a level, not an accumulator.
public enum GaugeName {
    /// CPU temperature in deci-degrees Celsius (°C × 10).
    public static let cpuTemperature = "cpuTemperature"
    /// Fan speed in whole revolutions per minute.
    public static let fanRPM = "fanRPM"
    /// Battery charge as a whole percent, 0…100.
    public static let batteryCharge = "batteryCharge"
    /// Ambient light as the raw sensor channel average. Uncalibrated and NOT lux (the key name is a
    /// historical artifact); surfaces caption it as a unitless level.
    public static let ambientLux = "ambientLux"
    /// Main-display backlight brightness in per mille (0…1000).
    public static let displayBrightness = "displayBrightness"
    /// Whole-system power draw in deci-watts (W × 10).
    public static let systemPowerWatts = "systemPowerWatts"
    /// Lid opening angle in whole degrees, where the HID sensor exists.
    public static let lidAngle = "lidAngle"
}

/// Pure edge- and delta-detection over sampled sensor readings, factored out of the collectors so the
/// counting rules are proven without any hardware. Every rule treats a nil baseline as "just started":
/// the first sample establishes state and never books a transition, exactly like `CounterAccumulator`.
public enum SensorSignal {
    /// True on a rising edge only: the value went from a known `false` to `true`. A nil (unseen) previous
    /// is a baseline and never counts, so lid opens and charging sessions are booked only at a real
    /// closed→open / not-charging→charging transition.
    public static func rose(previous: Bool?, current: Bool) -> Bool {
        previous == false && current
    }

    /// The positive increase from `previous` to `current`, or 0 when the count held, fell, or has no
    /// baseline. Used to book Bluetooth connect events as the rise in the connected-device count, so a
    /// disconnect (a fall) is never counted as a connect.
    public static func rise(previous: Int?, current: Int) -> Int {
        guard let previous, current > previous else { return 0 }
        return current - previous
    }

    /// True when the reading moved by more than `epsilon` from a known previous level. A nil previous is a
    /// baseline and never a change, so the audio collector books a volume change only on a real move and
    /// not on the first sample. `epsilon` guards against float jitter around an unchanged level.
    public static func changed(previous: Double?, current: Double, epsilon: Double) -> Bool {
        guard let previous else { return false }
        return abs(current - previous) > epsilon
    }

    /// True when the kernel boot time changed between launches, the mark of a reboot. A nil stored value
    /// is the first-ever launch and never counts a boot; an equal value is the same boot. The caller
    /// stores `current` afterwards so the next launch compares against it.
    public static func rebooted(previousBootTime: Int64?, current: Int64) -> Bool {
        guard let previousBootTime else { return false }
        return previousBootTime != current
    }
}
