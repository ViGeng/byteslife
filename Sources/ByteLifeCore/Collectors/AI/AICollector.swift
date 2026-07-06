import Foundation

/// The AI-family collector. It hosts one or more `AIUsageSource`s (Claude Code only in v1) and reports
/// an aggregate availability for the UI. Each source owns its own store writes; the collector only
/// drives their lifecycle and aggregates availability.
///
/// The collector owns one serial queue, which it hands to its default source so all AI file work runs
/// serially. A lightweight lock guards the small `started`/availability state. When no source is
/// available at launch (for example Claude Code is not installed yet), a lightweight recheck timer
/// polls until one appears, starts it, and then stops itself.
public final class AICollector: Collector, @unchecked Sendable {
    public let id = "ai.claudeCode"
    public let family: MetricFamily = .ai
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let queue: DispatchQueue
    private let store: SampleStore
    private let sources: [AIUsageSource]
    private let recheckInterval: DispatchTimeInterval
    /// A queue distinct from the source queue, so the recheck handler can call `source.start()`
    /// (which hops onto the source queue synchronously) without deadlocking.
    private let recheckQueue = DispatchQueue(label: "life.byte.ai.recheck")

    private let lock = NSLock()
    private var backingAvailability: Availability
    private var started = false
    private var startedSources: Set<ObjectIdentifier> = []
    private var recheck: Scheduler?

    /// Injecting `sources` is for tests; production passes nil to get the default Claude Code source
    /// bound to this collector's queue.
    public init(
        store: SampleStore,
        sources: [AIUsageSource]? = nil,
        recheckInterval: DispatchTimeInterval = .seconds(30)
    ) {
        let queue = DispatchQueue(label: "life.byte.ai")
        let resolved = sources ?? [ClaudeCodeSource(store: store, queue: queue)]
        self.queue = queue
        self.store = store
        self.sources = resolved
        self.recheckInterval = recheckInterval
        self.backingAvailability = Self.aggregate(resolved)
    }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        startAvailableSources()
        refreshAvailability()

        // If no source is available yet, its data root may appear later (the tool installed after
        // launch). Poll lightly until one shows up, then stop.
        if Self.aggregate(sources) != .running {
            let scheduler = Scheduler(queue: recheckQueue, interval: recheckInterval) { [weak self] in
                self?.recheckTick()
            }
            lock.lock(); recheck = scheduler; lock.unlock()
            scheduler.start()
        }
    }

    public func stop() {
        lock.lock()
        if !started { lock.unlock(); return }
        started = false
        let scheduler = recheck
        recheck = nil
        startedSources.removeAll()
        lock.unlock()

        scheduler?.stop()
        for source in sources { source.stop() }
        refreshAvailability()
    }

    /// Starts every available source exactly once. Sources own their store writes, so the emit hook
    /// is unused here.
    private func startAvailableSources() {
        for source in sources where source.isAvailable {
            let key = ObjectIdentifier(source)
            lock.lock()
            let already = startedSources.contains(key)
            if !already { startedSources.insert(key) }
            lock.unlock()
            guard !already else { continue }
            source.start(emit: { _ in })
        }
    }

    private func recheckTick() {
        startAvailableSources()
        refreshAvailability()
        // Once a source is available it stays installed, so stop polling.
        guard Self.aggregate(sources) == .running else { return }
        lock.lock(); let scheduler = recheck; recheck = nil; lock.unlock()
        scheduler?.stop()
    }

    private func refreshAvailability() {
        let newValue = Self.aggregate(sources)
        lock.lock()
        let changed = newValue != backingAvailability
        backingAvailability = newValue
        lock.unlock()
        if changed { onAvailabilityChange?(newValue) }
    }

    /// Running when any source's data root exists, otherwise the source is simply not installed here.
    private static func aggregate(_ sources: [AIUsageSource]) -> Availability {
        sources.contains { $0.isAvailable } ? .running : .sourceMissing
    }
}
