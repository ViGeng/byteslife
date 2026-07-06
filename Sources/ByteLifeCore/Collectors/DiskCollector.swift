import Foundation

/// Polls per-driver disk byte counters and records their additive deltas into the store.
///
/// Baselines are kept per block-storage driver ID and persisted in store meta, so restarts resume
/// from them and never double count. Availability is always running because the IOKit statistics path
/// needs no permission.
public final class DiskCollector: Collector, @unchecked Sendable {
    public let id = "disk"
    public let family: MetricFamily = .disk
    public var onAvailabilityChange: ((Availability) -> Void)?
    public var availability: Availability { .running }

    private let store: CounterStore
    private let read: () -> [DiskCounters]
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.disk")

    private let lock = NSLock()
    private var scheduler: Scheduler?

    // Per-driver baselines, seeded from persisted meta on first touch and advanced only after a
    // successful transactional write, so a failed commit leaves the next poll to re-emit the full delta.
    // Confined to `queue`, on which `poll` always runs.
    private var baselines: [String: UInt64] = [:]

    /// Injecting `read` lets tests drive the collector with scripted counters; production uses the
    /// real IOKit reader.
    public convenience init(
        store: SampleStore,
        interval: DispatchTimeInterval = .seconds(3),
        read: @escaping () -> [DiskCounters] = DiskStatistics.read
    ) {
        self.init(store: store as CounterStore, interval: interval, read: read)
    }

    /// Test seam: injects any `CounterStore`, including a store scripted to fail its writes.
    init(
        store: CounterStore,
        interval: DispatchTimeInterval = .seconds(3),
        read: @escaping () -> [DiskCounters] = DiskStatistics.read
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

    static func readKey(_ driverID: UInt64) -> String { "disk.baseline.read:\(driverID)" }
    static func writeKey(_ driverID: UInt64) -> String { "disk.baseline.write:\(driverID)" }

    /// One polling cycle: reduce each driver's counters against its baseline, then commit the summed
    /// read/write deltas and the new baselines in one transaction. Runs on `queue` in production; tests
    /// call it directly. Only positive deltas are recorded, so a first poll (all baselines nil) emits
    /// nothing.
    ///
    /// The in-memory baselines advance only after the write returns cleanly. If the write throws, they
    /// stay put so the next poll re-reads the same monotonic counters and re-emits the full delta: no
    /// interval is lost and none is double counted. We keep the error explicit (not `try?`) to make that
    /// ordering contract deliberate.
    func poll(now: Date = Date()) {
        var readDelta: Int64 = 0
        var writeDelta: Int64 = 0
        var meta: [String: Int64] = [:]

        for disk in read() {
            let readKey = Self.readKey(disk.driverID)
            let writeKey = Self.writeKey(disk.driverID)
            readDelta += CounterAccumulator.delta(previous: baseline(readKey), current: disk.bytesRead)
            writeDelta += CounterAccumulator.delta(previous: baseline(writeKey), current: disk.bytesWritten)
            meta[readKey] = Int64(bitPattern: disk.bytesRead)
            meta[writeKey] = Int64(bitPattern: disk.bytesWritten)
        }

        var samples: [Sample] = []
        if readDelta > 0 { samples.append(Sample(kind: .diskBytesRead, value: readDelta, timestamp: now)) }
        if writeDelta > 0 { samples.append(Sample(kind: .diskBytesWritten, value: writeDelta, timestamp: now)) }

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
