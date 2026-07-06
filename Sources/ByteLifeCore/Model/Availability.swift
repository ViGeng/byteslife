/// A collector's current operating state, aggregated by the registry for the UI.
public enum Availability: Sendable, Equatable {
    /// Actively collecting data.
    case running
    /// Blocked pending a TCC permission grant (for example Input Monitoring).
    case needsPermission
    /// The underlying data source is absent (for example Claude Code is not installed).
    case sourceMissing
    /// Turned off by the user.
    case disabled
}
