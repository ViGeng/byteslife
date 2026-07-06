import Foundation

/// One collector's availability, tagged with its id and family for the UI.
public struct CollectorAvailability: Sendable, Equatable {
    public let id: String
    public let family: MetricFamily
    public let availability: Availability

    public init(id: String, family: MetricFamily, availability: Availability) {
        self.id = id
        self.family = family
        self.availability = availability
    }
}

/// Owns the app's collectors, drives their lifecycle, and maintains an availability snapshot for
/// the UI.
///
/// The registry subscribes to each collector's `onAvailabilityChange`, records transitions into a
/// snapshot keyed by collector id, and forwards them to a single listener the owner (the UI) sets.
/// A `final class` guarded by one serial queue rather than an actor, matching `SampleStore`, so
/// collector callbacks arriving on their own queues update the snapshot synchronously. The snapshot
/// preserves collector order for stable UI rendering.
public final class CollectorRegistry: @unchecked Sendable {
    private let queue = DispatchQueue(label: "life.byte.CollectorRegistry")
    private let collectors: [Collector]

    private var snapshotByID: [String: CollectorAvailability]
    private var listener: ((CollectorAvailability) -> Void)?

    public init(collectors: [Collector]) {
        self.collectors = collectors
        var initial: [String: CollectorAvailability] = [:]
        for collector in collectors {
            initial[collector.id] = CollectorAvailability(
                id: collector.id,
                family: collector.family,
                availability: collector.availability
            )
        }
        snapshotByID = initial

        for collector in collectors {
            // Capture id and family by value, never the collector, so the callback does not retain
            // the collector that owns it.
            let id = collector.id
            let family = collector.family
            collector.onAvailabilityChange = { [weak self] availability in
                self?.handleChange(id: id, family: family, availability: availability)
            }
        }
    }

    /// The owner's listener for availability transitions. Reads and writes are queue-guarded.
    public var onAvailabilityChange: ((CollectorAvailability) -> Void)? {
        get { queue.sync { listener } }
        set { queue.sync { listener = newValue } }
    }

    /// Starts every collector, then refreshes the snapshot in case `start()` changed availability
    /// without firing a callback.
    public func startAll() {
        for collector in collectors { collector.start() }
        refreshSnapshot()
    }

    /// Stops every collector, then refreshes the snapshot.
    public func stopAll() {
        for collector in collectors { collector.stop() }
        refreshSnapshot()
    }

    /// The current availability of every collector, in the order collectors were registered.
    public func availabilitySnapshot() -> [CollectorAvailability] {
        queue.sync { collectors.map { snapshotByID[$0.id]! } }
    }

    /// The availability of a single collector, or nil if no collector has that id.
    public func availability(forID id: String) -> Availability? {
        queue.sync { snapshotByID[id]?.availability }
    }

    private func handleChange(id: String, family: MetricFamily, availability: Availability) {
        let entry = CollectorAvailability(id: id, family: family, availability: availability)
        // Update the snapshot under the queue, then invoke the listener outside it so a slow or
        // reentrant listener cannot stall other collectors' callbacks.
        let callback: ((CollectorAvailability) -> Void)? = queue.sync {
            snapshotByID[id] = entry
            return listener
        }
        callback?(entry)
    }

    private func refreshSnapshot() {
        let entries = collectors.map {
            CollectorAvailability(id: $0.id, family: $0.family, availability: $0.availability)
        }
        queue.sync {
            for entry in entries { snapshotByID[entry.id] = entry }
        }
    }
}
