import Foundation

/// Turns a sustained power reading over an elapsed span into whole milliwatt-hours to book, carrying
/// the sub-unit remainder forward so nothing is lost or double counted across ticks. Pure and
/// deterministic, mirroring the sub-second carry the screen collector uses for attentive seconds.
enum EnergyAccumulator {
    /// Adds `powerMilliwatts` held over `elapsedSeconds` to the fractional `carried` mWh, returning the
    /// whole mWh to emit and the new fractional carry. Non-positive power or elapsed contributes nothing
    /// but preserves the carry. Energy(mWh) = power(mW) * time(hours) = power(mW) * seconds / 3600.
    static func accumulate(
        powerMilliwatts: Double, elapsedSeconds: Double, carried: Double
    ) -> (emit: Int64, carry: Double) {
        guard powerMilliwatts > 0, elapsedSeconds > 0 else { return (0, carried) }
        let total = carried + powerMilliwatts * elapsedSeconds / 3_600.0
        let whole = total.rounded(.down)
        return (Int64(whole), total - whole)
    }
}

/// Books the machine's energy draw as additive `energyMilliwattHours` deltas.
///
/// Each tick reads instantaneous milliwatts from an injectable reader and integrates it over the
/// monotonic time since the last tick, using `CLOCK_UPTIME_RAW` so a system-sleep gap (when the clock
/// freezes and the machine draws nothing worth booking) is never counted. When the reader returns nil
/// there is no wattage signal (a desktop with no battery), so the collector reports `sourceMissing`
/// honestly and books nothing. All mutable state is confined to `queue`, on which the scheduler tick
/// runs; tests call `tick()` directly with an injected clock and reader.
public final class EnergyCollector: Collector, @unchecked Sendable {
    public let id = "energy"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let readMilliwatts: () -> Double?
    private let clock: () -> UInt64
    private let now: () -> Date
    private let tickInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.energy")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?

    // State touched only on `queue` (or directly by tests, which are single-threaded).
    private var lastMark: UInt64 = 0
    private var carriedMilliwattHours: Double = 0

    /// Injecting the reader and clock lets tests drive accrual deterministically; production reads live
    /// IOKit power and the monotonic uptime clock.
    public init(
        store: SampleStore,
        tickInterval: DispatchTimeInterval = .seconds(30),
        readMilliwatts: @escaping () -> Double? = PowerSource.milliwatts,
        clock: @escaping () -> UInt64 = ScreenCollector.uptimeNanos,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.tickInterval = tickInterval
        self.readMilliwatts = readMilliwatts
        self.clock = clock
        self.now = now
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

        queue.sync { self.lastMark = self.clock() }
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

    /// One integration step: advance the monotonic mark, read power, and book any whole milliwatt-hours
    /// accrued over the interval. A nil reading is an absent wattage signal, so we flag `sourceMissing`
    /// and skip. Runs on `queue`; tests call it directly.
    func tick() {
        let current = clock()
        let elapsedNanos = current &- lastMark
        lastMark = current

        guard let milliwatts = readMilliwatts() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)

        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000
        let result = EnergyAccumulator.accumulate(
            powerMilliwatts: milliwatts, elapsedSeconds: elapsedSeconds, carried: carriedMilliwattHours
        )
        carriedMilliwattHours = result.carry
        guard result.emit > 0 else { return }
        try? store.record([Sample(kind: .energyMilliwattHours, value: result.emit, timestamp: now())])
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }
}
