import Foundation

/// Derives a deterministic barcode from a receipt's 16-hex content hash, so the same receipt always
/// draws the same bars and two different receipts draw visibly different ones. The barcode is not a
/// scannable symbology; it is a tamper-evident fingerprint of the stored hash rendered as bar widths.
///
/// Each hex digit maps to a fixed pattern of two module widths: a bar width taken from the digit's high
/// two bits and a gap width from its low two bits, each in `1...4`. That per-digit map is a bijection, so
/// two hashes that differ in any digit produce arrays that differ at that digit's two entries. The
/// returned value is a flat list of module widths alternating bar (even index) then space (odd index).
public enum ReceiptBarcode {
    /// Modules emitted per hex digit: one bar width followed by one gap width.
    public static let modulesPerDigit = 2

    /// The alternating bar/space module widths for `contentHash`. Even indices are bars, odd indices are
    /// spaces; every width is in `1...4`. The count is `modulesPerDigit` times the number of characters
    /// in the hash (32 for the standard 16-hex hash). Non-hex characters, which the stored hash never
    /// contains, contribute a `0` value and so read as the flattest bar.
    public static func modules(for contentHash: String) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(contentHash.count * modulesPerDigit)
        for character in contentHash {
            let value = Int(String(character), radix: 16) ?? 0
            let barWidth = (value >> 2) + 1    // high two bits -> 1...4
            let gapWidth = (value & 0b11) + 1  // low two bits  -> 1...4
            result.append(barWidth)
            result.append(gapWidth)
        }
        return result
    }
}
