import Foundation
import ByteLifeCore

/// The UserDefaults keys the panel persists its adjustable chart windows under, shared by the view's
/// `@AppStorage` menus and the view model's fetch so both read one source of truth. Each adjustable
/// channel persists under `window.<channel raw value>`. The view writes them through `@AppStorage`; the
/// view model reads them here to prime its fetch depth and bucketing before the panel first opens,
/// avoiding a first-frame window mismatch.
enum ChartWindowStore {
    /// The rate channels that carry a window selector. EXPOSURE has no sparkline to zoom, so it is absent.
    static let adjustableChannels: [MeterChannelKind] = [.traffic, .storage, .cognition, .mechanics]

    static func key(_ kind: MeterChannelKind) -> String { "window.\(kind.rawValue)" }
    /// The one global WORK-window duration in minutes, shared by every chart's WORK option.
    static let workMinutesKey = "window.work.minutes"
    /// The WORK window's default span: eight hours, a working day.
    static let defaultWorkMinutes = 480

    /// The persisted window for a key, defaulting to 30M when unset or unrecognized.
    static func window(_ key: String, in defaults: UserDefaults = .standard) -> MeterWindow {
        defaults.string(forKey: key).flatMap(MeterWindow.init(rawValue:)) ?? .default
    }

    /// The persisted per-channel window map for the adjustable channels.
    static func channelWindows(in defaults: UserDefaults = .standard) -> [MeterChannelKind: MeterWindow] {
        Dictionary(uniqueKeysWithValues: adjustableChannels.map { ($0, window(key($0), in: defaults)) })
    }
}
