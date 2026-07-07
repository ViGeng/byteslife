import SwiftUI
import ByteLifeCore

/// The Byte Flow faceplate palette. The deck now tracks the system appearance: every role resolves
/// against the current color scheme so the panel reads as a dark instrument in dark mode and a light
/// instrument in light mode, while every glow and pulse it colors is still driven by real data (light
/// is data). Each channel owns exactly one signal color, tuned per scheme so a glance reads the day's
/// shape by color alone. Brass gold never appears here — it stays reserved for the BALANCED stamp on
/// ledger surfaces.
///
/// Every role is a function of `ColorScheme`; call sites read `@Environment(\.colorScheme)` and pass it
/// in, so a single environment value drives the whole deck. Dark keeps the shipped values exactly; the
/// light variants are the pinned Iteration 5 values.
enum LatticePalette {
    // MARK: Chassis, cards, hairlines, dial

    /// The chassis behind everything: near-black blue-charcoal on dark, a cool off-white on light.
    static func chassis(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x0B / 255, green: 0x0E / 255, blue: 0x11 / 255)
            : Color(red: 0xF2 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    }

    /// Raised channel cards.
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x12 / 255, green: 0x17 / 255, blue: 0x1C / 255)
            : Color(red: 0xFF / 255, green: 0xFF / 255, blue: 0xFF / 255)
    }

    /// Hairlines, card strokes, and chart grid rules.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x1E / 255, green: 0x26 / 255, blue: 0x2D / 255)
            : Color(red: 0xDD / 255, green: 0xE4 / 255, blue: 0xEA / 255)
    }

    /// Dial text: a cool off-white on dark, a deep slate on light.
    static func dial(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xE8 / 255, green: 0xED / 255, blue: 0xF2 / 255)
            : Color(red: 0x1A / 255, green: 0x21 / 255, blue: 0x29 / 255)
    }

    /// Secondary dial text.
    static func dim(_ scheme: ColorScheme) -> Color { dial(scheme).opacity(0.55) }

    // MARK: Channel signal colors

    static func teal(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x46 / 255, green: 0xE0 / 255, blue: 0xC8 / 255)
            : Color(red: 0x0E / 255, green: 0x9C / 255, blue: 0x86 / 255)
    }

    static func violet(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x9B / 255, green: 0x8C / 255, blue: 0xFF / 255)
            : Color(red: 0x6B / 255, green: 0x5A / 255, blue: 0xE0 / 255)
    }

    static func amber(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x17 / 255)
            : Color(red: 0xB8 / 255, green: 0x7E / 255, blue: 0x0A / 255)
    }

    static func green(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x5F / 255, green: 0xC4 / 255, blue: 0x6A / 255)
            : Color(red: 0x3D / 255, green: 0x9C / 255, blue: 0x4C / 255)
    }

    static func coral(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x5B / 255)
            : Color(red: 0xE0 / 255, green: 0x50 / 255, blue: 0x3E / 255)
    }

    static func channel(_ kind: MeterChannelKind, _ scheme: ColorScheme) -> Color {
        switch kind {
        case .traffic: return teal(scheme)
        case .storage: return violet(scheme)
        case .cognition: return amber(scheme)
        case .exposure: return green(scheme)
        case .mechanics: return coral(scheme)
        }
    }

    // MARK: Glow

    /// Multiplier applied to every glow-shadow opacity. Glows soften on light (about half strength) so
    /// they read as warmth rather than blur, while dark keeps the shipped full-strength glow.
    static func glow(_ scheme: ColorScheme) -> Double { scheme == .dark ? 1.0 : 0.5 }
}
