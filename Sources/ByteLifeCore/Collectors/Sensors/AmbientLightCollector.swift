import Foundation
import IOKit

/// Books the ambient-light level per minute into the `ambientLux` gauge.
///
/// A 60 s tick reads an injectable lux value (production: the legacy `AppleLMUController` IOKit user
/// client, whose two raw ALS channels are averaged as a coarse lux proxy). Many Apple Silicon Macs moved
/// the sensor to HID and expose no LMU service, so the reader returns nil there and the collector degrades
/// to `sourceMissing` honestly. All mutable state is confined to `queue`; tests inject the reader and clock
/// and call `tick()` directly.
public final class AmbientLightCollector: Collector, @unchecked Sendable {
    public let id = "ambient"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let readLux: () -> Double?
    private let now: () -> Date
    private let tickInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.ambient")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?

    public init(
        store: SampleStore,
        tickInterval: DispatchTimeInterval = .seconds(60),
        now: @escaping () -> Date = Date.init,
        readLux: @escaping () -> Double? = AmbientLightCollector.appleLMULux
    ) {
        self.store = store
        self.tickInterval = tickInterval
        self.now = now
        self.readLux = readLux
    }

    deinit { stop() }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    public func start() {
        lock.lock()
        let alreadyRunning = scheduler != nil
        lock.unlock()
        guard !alreadyRunning else { return }
        let scheduler = Scheduler(queue: queue, interval: tickInterval) { [weak self] in self?.tick() }
        lock.lock(); self.scheduler = scheduler; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        lock.unlock()
    }

    /// One tick: sample the lux level into the gauge, or degrade to `sourceMissing` when the sensor is
    /// absent. Runs on `queue`; tests call it directly.
    func tick() {
        guard let lux = readLux() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)
        let bucket = DayBucket(date: now())
        try? store.recordGauge(
            dayEpoch: bucket.dayEpoch, minute: bucket.minute,
            gauge: GaugeName.ambientLux, value: Int64(max(0, lux).rounded())
        )
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// Reads the legacy `AppleLMUController` ambient-light user client, averaging its two raw ALS channels
    /// as a coarse lux proxy. Returns nil when the service is absent (most Apple Silicon Macs) or the call
    /// fails, so the collector degrades honestly.
    public static func appleLMULux() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleLMUController"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        defer { IOServiceClose(connection) }

        var outputs: [UInt64] = [0, 0]
        var outputCount: UInt32 = 2
        let result = IOConnectCallMethod(connection, 0, nil, 0, nil, 0, &outputs, &outputCount, nil, nil)
        guard result == kIOReturnSuccess, outputCount >= 1 else { return nil }
        let channels = Array(outputs.prefix(Int(outputCount)))
        return Double(channels.reduce(0, +)) / Double(channels.count)
    }
}
