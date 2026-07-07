import SwiftUI
import ByteLifeCore

/// The Byte Flow faceplate palette. The panel is a live surface for byte data and is ALWAYS dark in
/// both appearances; every glow and pulse it colors is driven by real data (light is data). Each
/// channel owns exactly one signal color, taken from the concept research palettes, so a glance reads
/// the day's shape by color alone. Brass gold never appears here — it stays reserved for the BALANCED
/// stamp on ledger surfaces.
enum LatticePalette {
    /// The near-black blue-charcoal chassis behind everything.
    static let chassis = Color(red: 0x0B / 255, green: 0x0E / 255, blue: 0x11 / 255)
    /// Raised channel cards.
    static let card = Color(red: 0x12 / 255, green: 0x17 / 255, blue: 0x1C / 255)
    /// Hairlines, card strokes, and chart grid rules.
    static let hairline = Color(red: 0x1E / 255, green: 0x26 / 255, blue: 0x2D / 255)
    /// Dial text: a cool off-white.
    static let dial = Color(red: 0xE8 / 255, green: 0xED / 255, blue: 0xF2 / 255)
    /// Secondary dial text.
    static var dim: Color { dial.opacity(0.55) }

    /// The channel signal colors.
    static let teal = Color(red: 0x46 / 255, green: 0xE0 / 255, blue: 0xC8 / 255)
    static let violet = Color(red: 0x9B / 255, green: 0x8C / 255, blue: 0xFF / 255)
    static let amber = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x17 / 255)
    static let green = Color(red: 0x5F / 255, green: 0xC4 / 255, blue: 0x6A / 255)
    static let coral = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x5B / 255)

    static func channel(_ kind: MeterChannelKind) -> Color {
        switch kind {
        case .traffic: return teal
        case .storage: return violet
        case .cognition: return amber
        case .exposure: return green
        case .mechanics: return coral
        }
    }
}
