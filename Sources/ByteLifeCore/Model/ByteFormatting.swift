import Foundation

/// Pure, deterministic, locale-independent formatters for the UI.
/// Output is fixed regardless of the user's locale because tests assert exact strings.
/// `String(format:)` with no locale argument uses the C locale, so decimals always use a period.
public enum ByteFormatting {
    private static let byteUnits = ["KB", "MB", "GB", "TB", "PB", "EB"]

    /// Pixels per inch assumed for a Retina-class display, used to convert recorded mouse travel
    /// into a physical distance. Fixed here as an explicit, documented assumption per PLAN.md rather
    /// than probed from hardware, so the Labor Account's "distance hauled" is reproducible.
    public static let assumedPixelsPerInch = 220.0

    /// Meters in one inch. The mouse-travel conversion multiplies through this exact constant.
    private static let metersPerInch = 0.0254

    /// Formats a byte count with binary (1024-based) units, e.g. 1536 -> "1.5 KB", 0 -> "0 B".
    public static func bytes(_ count: Int64) -> String {
        if count < 1024 {
            return "\(count) B"
        }
        var value = Double(count)
        var unitIndex = -1
        while value >= 1024 && unitIndex < byteUnits.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return "\(oneDecimal(value)) \(byteUnits[unitIndex])"
    }

    /// Formats a token count compactly, e.g. 512 -> "512", 1500 -> "1.5K", 2_500_000 -> "2.5M".
    public static func tokens(_ count: Int64) -> String {
        compact(count)
    }

    /// Formats an exact integer with comma thousands separators, e.g. 4200 -> "4,200",
    /// 1_234_567 -> "1,234,567". Grouping is done by hand so it stays locale-independent, which the
    /// ledger's itemized token and keystroke lines rely on for byte-for-byte stable receipts.
    public static func grouped(_ count: Int64) -> String {
        if count == 0 { return "0" }
        let negative = count < 0
        // Accumulate three-digit chunks from least significant, zero-padding every chunk but the top.
        var magnitude = negative ? String(count).dropFirst() : Substring(String(count))
        var chunks: [String] = []
        while magnitude.count > 3 {
            chunks.insert(String(magnitude.suffix(3)), at: 0)
            magnitude = magnitude.dropLast(3)
        }
        chunks.insert(String(magnitude), at: 0)
        let joined = chunks.joined(separator: ",")
        return negative ? "-" + joined : joined
    }

    /// Formats a duration strictly as zero-padded HH:MM, e.g. 24120 -> "06:42", 0 -> "00:00".
    /// The Hours Under the Lamp account books time in this fixed-width form so ledger rows align.
    /// Hours are not capped at 24, since an accounting period can in principle exceed a day.
    public static func hoursMinutes(seconds: Int64) -> String {
        let total = max(0, seconds)
        return String(format: "%02lld:%02lld", total / 3600, (total % 3600) / 60)
    }

    /// Converts recorded mouse travel (milli-pixels) to meters at `assumedPixelsPerInch`.
    public static func meters(milliPixels: Int64) -> Double {
        let pixels = Double(milliPixels) / 1000
        return pixels / assumedPixelsPerInch * metersPerInch
    }

    /// Human-legible mouse travel for the Labor Account's "Distance Hauled" line: meters below one
    /// kilometer, kilometers above, e.g. 300 m -> "300 m", 1200 m -> "1.2 km".
    public static func distanceHauled(milliPixels: Int64) -> String {
        let m = meters(milliPixels: milliPixels)
        if m < 1000 { return "\(Int(m.rounded())) m" }
        return "\(oneDecimal(m / 1000)) km"
    }

    /// Formats a duration as hours and minutes, e.g. 12240 -> "3h 24m", 60 -> "1m", 0 -> "0s".
    /// Seconds only appear below one minute; hours always carry an explicit minutes field.
    public static func duration(seconds: Int64) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(secs)s"
    }

    /// Formats mouse travel (stored as milli-pixels) as a compact pixel distance, e.g.
    /// 512_000 -> "512 px", 1_500_000 -> "1.5K px".
    public static func pixelDistance(milliPixels: Int64) -> String {
        "\(compact(milliPixels / 1000)) px"
    }

    /// Formats a throughput in bytes per second on the same binary-unit ladder as `bytes`, suffixed
    /// "/s", e.g. 2_202_010 -> "2.1 MB/s", 500 -> "500 B/s", 0 -> "0 B/s". The rate is rounded to whole
    /// bytes first, so sub-byte jitter never leaks into the reading. Used by the Meter Bridge's TRAFFIC
    /// and STORAGE channels.
    public static func byteRate(_ bytesPerSecond: Double) -> String {
        let count = Int64(max(0, bytesPerSecond).rounded())
        return bytes(count) + "/s"
    }

    /// Formats a throughput in tokens per minute compactly, e.g. 312 -> "312 tok/min",
    /// 1_500 -> "1.5K tok/min". Used by the Meter Bridge's COGNITION channel.
    public static func tokenRate(_ tokensPerMinute: Double) -> String {
        "\(compact(Int64(max(0, tokensPerMinute).rounded()))) tok/min"
    }

    /// Formats a typing cadence in keystrokes per minute as the instrument's "kpm" reading, e.g.
    /// 42 -> "42 kpm", 312 -> "312 kpm". Used by the Meter Bridge's MECHANICS channel.
    public static func keyRate(_ keysPerMinute: Double) -> String {
        "\(Int64(max(0, keysPerMinute).rounded())) kpm"
    }

    /// A byte delta as raw hexadecimal ("0x1F4A2"), the panel's hex ticker unit. Negative deltas clamp
    /// to zero: the ticker prints flow, never accounting noise.
    public static func hex(_ value: Int64) -> String {
        "0x" + String(max(0, value), radix: 16, uppercase: true)
    }

    /// Compact magnitude formatting shared by token and pixel output: K/M/B suffixes above 1000.
    private static func compact(_ count: Int64) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 { return "\(oneDecimal(Double(count) / 1_000))K" }
        if count < 1_000_000_000 { return "\(oneDecimal(Double(count) / 1_000_000))M" }
        return "\(oneDecimal(Double(count) / 1_000_000_000))B"
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
