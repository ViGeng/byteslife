import Foundation

/// Pure, deterministic, locale-independent formatters for the UI.
/// Output is fixed regardless of the user's locale because tests assert exact strings.
/// `String(format:)` with no locale argument uses the C locale, so decimals always use a period.
public enum ByteFormatting {
    private static let byteUnits = ["KB", "MB", "GB", "TB", "PB", "EB"]

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
