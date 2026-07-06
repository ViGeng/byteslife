/// A single metric source that the registry owns, starts, and stops.
///
/// Collectors are reference types: each owns its own serial `DispatchQueue` (or, for the input
/// tap, a dedicated run-loop thread) and mutates state only there. `availability` must be safe to
/// read from any thread, since the UI polls it off the collector's own queue. A collector announces
/// state transitions by invoking `onAvailabilityChange`, which the registry sets so it can keep its
/// UI snapshot current.
public protocol Collector: AnyObject {
    /// Stable identifier, unique within a registry (for example "ai.claudeCode").
    var id: String { get }

    /// The metric family this collector feeds.
    var family: MetricFamily { get }

    /// Current operating state. Safe to read from any thread.
    var availability: Availability { get }

    /// Set by the registry. The collector calls this whenever `availability` transitions so the
    /// registry can refresh its snapshot and forward the change to the UI.
    var onAvailabilityChange: ((Availability) -> Void)? { get set }

    /// Begins collecting. Idempotent: a second call while already running is a no-op.
    func start()

    /// Stops collecting and releases any OS resources. Idempotent.
    func stop()
}
