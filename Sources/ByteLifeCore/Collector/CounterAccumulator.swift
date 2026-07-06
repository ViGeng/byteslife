/// Reduces a monotonic since-boot counter (network or disk byte totals) into an additive delta
/// that is always safe to accumulate.
///
/// Such counters reset to zero on reboot or when a device is re-enumerated. The rules per PLAN.md:
/// - No previous baseline yet: baseline silently, emitting `0`.
/// - The counter rose or held steady: emit the difference.
/// - The counter fell: treat it as a reset, re-baseline at `current`, and emit `0` rather than a
///   wrapped, enormous value.
///
/// In every case the caller stores `current` as the next baseline; this function only decides how
/// much to emit.
public enum CounterAccumulator {
    public static func delta(previous: UInt64?, current: UInt64) -> Int64 {
        guard let previous else { return 0 }
        guard current >= previous else { return 0 }
        // A single sample interval never legitimately exceeds Int64.max bytes, so clamp defensively.
        return Int64(clamping: current - previous)
    }
}
