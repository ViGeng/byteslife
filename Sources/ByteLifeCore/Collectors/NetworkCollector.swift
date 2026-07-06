import Foundation

/// Polls per-interface byte counters and records their additive deltas into the store.
///
/// Baselines are kept per interface, never on a summed total, so a vanished VPN or unplugged USB
/// interface is never misread as a global counter reset. Each interface's last-seen counters live in
/// store meta, so an app restart resumes from them and never double counts. Availability is always
/// running because the sysctl path needs no permission.
public final class NetworkCollector: Collector, @unchecked Sendable {
    public let id = "network"
    public let family: MetricFamily = .network
    public var onAvailabilityChange: ((Availability) -> Void)?
    public var availability: Availability { .running }

    private let store: CounterStore
    private let read: () -> [InterfaceCounters]
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.network")

    private let lock = NSLock()
    private var scheduler: Scheduler?

    // Per-interface baselines, seeded from persisted meta on first touch and advanced only after a
    // successful transactional write, so a failed commit leaves the next poll to re-emit the full delta.
    // Confined to `queue`, on which `poll` always runs.
    private var baselines: [String: UInt64] = [:]

    /// Injecting `read` lets tests drive the collector with scripted counters; production uses the
    /// real sysctl reader.
    public convenience init(
        store: SampleStore,
        interval: DispatchTimeInterval = .seconds(3),
        read: @escaping () -> [InterfaceCounters] = NetworkInterfaces.read
    ) {
        self.init(store: store as CounterStore, interval: interval, read: read)
    }

    /// Test seam: injects any `CounterStore`, including a store scripted to fail its writes.
    init(
        store: CounterStore,
        interval: DispatchTimeInterval = .seconds(3),
        read: @escaping () -> [InterfaceCounters] = NetworkInterfaces.read
    ) {
        self.store = store
        self.read = read
        self.interval = interval
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard scheduler == nil else { return }
        let scheduler = Scheduler(queue: queue, interval: interval) { [weak self] in self?.poll() }
        self.scheduler = scheduler
        scheduler.start()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        scheduler?.stop()
        scheduler = nil
    }

    static func inKey(_ name: String) -> String { "net.baseline.in:\(name)" }
    static func outKey(_ name: String) -> String { "net.baseline.out:\(name)" }

    /// One polling cycle: reduce each interface's counters against its baseline, then commit the summed
    /// in/out deltas and the new baselines in one transaction. Runs on `queue` in production; tests call
    /// it directly. Only positive deltas are recorded, so a first poll (all baselines nil) emits nothing.
    ///
    /// The in-memory baselines advance only after the write returns cleanly. If the write throws, they
    /// stay put so the next poll re-reads the same monotonic counters and re-emits the full delta: no
    /// interval is lost and none is double counted. We keep the error explicit (not `try?`) to make that
    /// ordering contract deliberate.
    func poll(now: Date = Date()) {
        var inDelta: Int64 = 0
        var outDelta: Int64 = 0
        var meta: [String: Int64] = [:]

        for interface in read() {
            let inKey = Self.inKey(interface.name)
            let outKey = Self.outKey(interface.name)
            inDelta += CounterAccumulator.delta(previous: baseline(inKey), current: interface.bytesIn)
            outDelta += CounterAccumulator.delta(previous: baseline(outKey), current: interface.bytesOut)
            meta[inKey] = Int64(bitPattern: interface.bytesIn)
            meta[outKey] = Int64(bitPattern: interface.bytesOut)
        }

        var samples: [Sample] = []
        if inDelta > 0 { samples.append(Sample(kind: .networkBytesIn, value: inDelta, timestamp: now)) }
        if outDelta > 0 { samples.append(Sample(kind: .networkBytesOut, value: outDelta, timestamp: now)) }

        do {
            try store.record(samples, settingMeta: meta)
        } catch {
            return
        }
        for (key, value) in meta { baselines[key] = UInt64(bitPattern: value) }
    }

    private func baseline(_ key: String) -> UInt64? {
        if let cached = baselines[key] { return cached }
        guard let persisted = (try? store.metaInt(key)).flatMap({ $0 }) else { return nil }
        let value = UInt64(bitPattern: persisted)
        baselines[key] = value
        return value
    }
}
