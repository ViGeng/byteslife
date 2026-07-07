import Foundation

/// Books the SMC-derived thermal curves and a thermal-state change memo.
///
/// A 60 s tick samples three per-minute gauges through injectable readers that default to the shared SMC
/// client: CPU temperature (deci-degrees Celsius), fan RPM, and whole-system power (deci-watts). The
/// temperature reader tries a small list of candidate keys and takes the first readable one, because the
/// key differs across models: Intel exposes `TC0P`/`TC0D`, Apple Silicon exposes many per-core `Tp..`
/// keys, of which the first readable stands in for the cluster. A fanless Mac simply has no `F0Ac` key,
/// so the fan gauge is skipped while temperature still books. Availability follows the temperature reader:
/// `running` while it reads, `sourceMissing` on a machine with no accessible SMC.
///
/// Independently of the SMC gauges, the collector counts `ProcessInfo.thermalState` changes, a permission-
/// free public signal that books even when the SMC is unreadable. Because it is a rare, four-level memo
/// rather than a curve or one of the deck's counter kinds, it is kept as a per-day meta counter under the
/// key `thermal.stateChanges:<dayEpoch>`, which the day story reads through. All mutable state is confined
/// to `queue`; tests inject the readers and clock and call `tick()` / `recordThermalStateIfChanged()`.
public final class ThermalCollector: Collector, @unchecked Sendable {
    public let id = "thermal"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    /// The per-day meta key holding the running count of thermal-state changes for `dayEpoch`.
    public static func thermalChangesKey(dayEpoch: Int64) -> String { "thermal.stateChanges:\(dayEpoch)" }

    /// The SMC key candidates for CPU temperature, tried in order: Intel proximity/die first, then a few
    /// representative Apple Silicon per-core keys.
    public static let temperatureKeys = ["TC0P", "TC0D", "Tp09", "Tp01", "Tp05", "Tp0D"]

    private let store: SampleStore
    private let readTemperatureCelsius: () -> Double?
    private let readFanRPM: () -> Double?
    private let readMilliwatts: () -> Double?
    private let readThermalState: () -> Int
    private let now: () -> Date
    private let tickInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.thermal")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?
    private var observer: NSObjectProtocol?

    // Confined to `queue` (or driven directly by single-threaded tests).
    private var previousThermalLevel: Int?

    /// Injecting the readers and clock lets tests drive the curves and the change count deterministically;
    /// production reads the live SMC keys, the battery/SMC power path, and `ProcessInfo.thermalState`.
    public init(
        store: SampleStore,
        tickInterval: DispatchTimeInterval = .seconds(60),
        now: @escaping () -> Date = Date.init,
        readTemperatureCelsius: @escaping () -> Double? = ThermalCollector.smcTemperature,
        readFanRPM: @escaping () -> Double? = { SMCReader.shared.read(key: "F0Ac") },
        readMilliwatts: @escaping () -> Double? = { SystemPower.milliwatts() },
        readThermalState: @escaping () -> Int = ThermalCollector.processThermalLevel
    ) {
        self.store = store
        self.tickInterval = tickInterval
        self.now = now
        self.readTemperatureCelsius = readTemperatureCelsius
        self.readFanRPM = readFanRPM
        self.readMilliwatts = readMilliwatts
        self.readThermalState = readThermalState
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

        // A thermal-state change books immediately via the public notification, not only on the next tick.
        let token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.recordThermalStateIfChanged() }
        }
        let scheduler = Scheduler(queue: queue, interval: tickInterval) { [weak self] in self?.tick() }
        lock.lock(); self.scheduler = scheduler; self.observer = token; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        let token = observer
        observer = nil
        lock.unlock()
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// One sampling tick: write whichever SMC gauges read, set availability from the temperature reader,
    /// and re-check the thermal state so a missed notification is still caught. Runs on `queue`; tests
    /// call it directly.
    func tick() {
        let bucket = DayBucket(date: now())

        if let celsius = readTemperatureCelsius() {
            setAvailability(.running)
            recordGauge(bucket, GaugeName.cpuTemperature, Int64((celsius * 10).rounded()))
        } else {
            setAvailability(.sourceMissing)
        }
        if let rpm = readFanRPM() {
            recordGauge(bucket, GaugeName.fanRPM, Int64(rpm.rounded()))
        }
        if let milliwatts = readMilliwatts(), milliwatts > 0 {
            recordGauge(bucket, GaugeName.systemPowerWatts, Int64((milliwatts / 100).rounded()))
        }

        recordThermalStateIfChanged()
    }

    /// Increments the per-day thermal-state change counter when the level moved since the last reading.
    /// The first reading only baselines. Runs on `queue`; tests call it directly.
    func recordThermalStateIfChanged() {
        let level = readThermalState()
        defer { previousThermalLevel = level }
        guard let previous = previousThermalLevel, previous != level else { return }
        let key = Self.thermalChangesKey(dayEpoch: DayBucket.dayEpoch(for: now()))
        let current = (try? store.metaInt(key)).flatMap { $0 } ?? 0
        try? store.setMetaInt(key, current + 1)
    }

    private func recordGauge(_ bucket: DayBucket, _ gauge: String, _ value: Int64) {
        try? store.recordGauge(dayEpoch: bucket.dayEpoch, minute: bucket.minute, gauge: gauge, value: value)
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// The first readable CPU-temperature key from `temperatureKeys`, or nil when none read a plausible
    /// value. A reading outside −50…150 °C is treated as no signal (a stale or bogus key).
    public static func smcTemperature() -> Double? {
        for key in temperatureKeys {
            if let celsius = SMCReader.shared.read(key: key), celsius > -50, celsius < 150 {
                return celsius
            }
        }
        return nil
    }

    /// The raw `ProcessInfo.thermalState` level: 0 nominal, 1 fair, 2 serious, 3 critical.
    public static func processThermalLevel() -> Int {
        ProcessInfo.processInfo.thermalState.rawValue
    }
}
