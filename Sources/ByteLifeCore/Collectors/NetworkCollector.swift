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

    private let store: SampleStore
    private let read: () -> [InterfaceCounters]
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.network")

    private let lock = NSLock()
    private var scheduler: Scheduler?

    // Per-interface baselines, seeded from persisted meta on first touch and advanced only after a
    // successful transactional write, so a failed commit leaves the next poll to re-emit the full delta.
    // Confined to `queue`, on which `poll` always runs.
    private var baselines: [String: UInt64] = [:]
    private var previousConnections: [String: NetworkConnection] = [:]
    private var previousPoll: Date?

    /// Injecting `read` lets tests drive the collector with scripted counters; production uses the
    /// real sysctl reader.
    public init(
        store: SampleStore,
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

    /// Commits the directional deltas, connection breakdown and new baselines together.
    /// Runs on `queue` in production. Tests call it directly.
    func poll(now: Date = Date()) {
        var traffic: [NetworkTraffic] = []
        var meta: [String: Int64] = [:]
        var connections: [String: NetworkConnection] = [:]
        // The normal poll is three seconds. After a longer gap (sleep or delayed sampling), the
        // endpoints no longer provide enough evidence to name the Wi-Fi network for the whole delta.
        let gap = previousPoll.map { now.timeIntervalSince($0) } ?? .infinity
        let nearby = (0...10).contains(gap)

        for interface in read() {
            let inKey = Self.inKey(interface.name)
            let outKey = Self.outKey(interface.name)
            let inDelta = CounterAccumulator.delta(previous: baseline(inKey), current: interface.bytesIn)
            let outDelta = CounterAccumulator.delta(previous: baseline(outKey), current: interface.bytesOut)
            meta[inKey] = Int64(bitPattern: interface.bytesIn)
            meta[outKey] = Int64(bitPattern: interface.bytesOut)
            connections[interface.name] = interface.connection

            guard inDelta > 0 || outDelta > 0 else { continue }
            var connection = interface.connection
            if case .wifi = connection, !nearby || previousConnections[interface.name] != connection {
                connection = .wifi(ssid: nil)
            }
            traffic.append(NetworkTraffic(connection: connection, bytesIn: inDelta, bytesOut: outDelta))
        }

        do {
            try store.recordNetwork(traffic, at: now, settingMeta: meta)
        } catch {
            // Keep the byte baselines for the retry. The retained interval may now span a switch.
            previousConnections.removeAll()
            return
        }
        for (key, value) in meta { baselines[key] = UInt64(bitPattern: value) }
        previousConnections = connections
        previousPoll = now
    }

    private func baseline(_ key: String) -> UInt64? {
        if let cached = baselines[key] { return cached }
        guard let persisted = (try? store.metaInt(key)).flatMap({ $0 }) else { return nil }
        let value = UInt64(bitPattern: persisted)
        baselines[key] = value
        return value
    }
}
