import SwiftUI

/// The Double-Entry Self palette, fixed hex from the concept sheet. Every colour the Ledger panel uses
/// resolves through here, so the discipline holds in one place: brass gold marks the balanced / POSTED
/// state and nothing else.
enum LedgerPalette {
    /// Warm off-white ledger paper, the light-mode surface.
    static let paper = Color(red: 0xF4 / 255, green: 0xF1 / 255, blue: 0xE9 / 255)
    /// Deep ink-navy, the dark-mode surface.
    static let inkNavy = Color(red: 0x14 / 255, green: 0x1A / 255, blue: 0x24 / 255)
    /// Debits: a desaturated oxblood red.
    static let debit = Color(red: 0x9B / 255, green: 0x3B / 255, blue: 0x2F / 255)
    /// Credits: a muted ledger green.
    static let credit = Color(red: 0x3B / 255, green: 0x6B / 255, blue: 0x4A / 255)
    /// Running balances and account names: near-black ink for light paper.
    static let ink = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1A / 255)
    /// Hairline account rules: a faded pencil gray.
    static let pencil = Color(red: 0xC9 / 255, green: 0xC2 / 255, blue: 0xB2 / 255)
    /// The single accent, brass-ledger gold, reserved for the balanced / POSTED impression alone.
    static let brass = Color(red: 0xB5 / 255, green: 0x8A / 255, blue: 0x3C / 255)

    /// The paper surface for the current appearance.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? inkNavy : paper
    }

    /// Primary ink for the current appearance: near-black on paper, warm paper on ink-navy.
    static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? paper : ink
    }
}
