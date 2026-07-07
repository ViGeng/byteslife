import Foundation
import IOKit

/// One battery snapshot: the charge as a percent, whether it is charging, and its lifetime cycle count.
public struct BatteryReading: Equatable, Sendable {
    /// Charge as a percent, 0…100.
    public let chargePercent: Double
    /// True while the pack is taking charge (AC attached and charge rising).
    public let isCharging: Bool
    /// Lifetime charge cycles, or nil when the battery does not report it.
    public let cycleCount: Int?

    public init(chargePercent: Double, isCharging: Bool, cycleCount: Int?) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.cycleCount = cycleCount
    }
}

/// Books the battery charge curve, the count of charging sessions, and the lifetime cycle count.
///
/// A 60 s tick reads an injectable `BatteryReading` (production: the `AppleSmartBattery` IOKit service).
/// The charge percent is written per minute into the `batteryCharge` gauge. A not-charging→charging edge
/// books one charging session, exactly the "AC attach with rising charge" event, into the per-day meta
/// counter `battery.chargingSessions:<dayEpoch>`. The cycle count is a fact, not a series, so it is stored
/// as the read-through meta value `battery.cycleCount` for the day story memo. Availability follows the
/// reader: `running` on a portable, `sourceMissing` on a desktop with no battery. All mutable state is
/// confined to `queue`; tests inject the reader and clock and call `tick()` directly.
public final class BatteryCollector: Collector, @unchecked Sendable {
    public let id = "battery"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    /// The per-day meta key holding the count of charging sessions begun on `dayEpoch`.
    public static func chargingSessionsKey(dayEpoch: Int64) -> String {
        "battery.chargingSessions:\(dayEpoch)"
    }
    /// The read-through meta key holding the latest lifetime cycle count.
    public static let cycleCountKey = "battery.cycleCount"

    private let store: SampleStore
    private let readBattery: () -> BatteryReading?
    private let now: () -> Date
    private let tickInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.battery")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?

    // Confined to `queue` (or driven directly by single-threaded tests).
    private var previousCharging: Bool?

    /// Injecting the reader and clock lets tests drive the curve and the session edge deterministically;
    /// production reads the live `AppleSmartBattery` service.
    public init(
        store: SampleStore,
        tickInterval: DispatchTimeInterval = .seconds(60),
        now: @escaping () -> Date = Date.init,
        readBattery: @escaping () -> BatteryReading? = BatteryCollector.readAppleSmartBattery
    ) {
        self.store = store
        self.tickInterval = tickInterval
        self.now = now
        self.readBattery = readBattery
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

    /// One tick: write the charge gauge, book a charging session on the charging edge, and store the cycle
    /// count fact. A machine with no battery degrades to `sourceMissing`. Runs on `queue`; tests call it
    /// directly.
    func tick() {
        guard let reading = readBattery() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)

        let bucket = DayBucket(date: now())
        let percent = Int64(min(100, max(0, reading.chargePercent)).rounded())
        try? store.recordGauge(
            dayEpoch: bucket.dayEpoch, minute: bucket.minute,
            gauge: GaugeName.batteryCharge, value: percent
        )

        if SensorSignal.rose(previous: previousCharging, current: reading.isCharging) {
            let key = Self.chargingSessionsKey(dayEpoch: bucket.dayEpoch)
            let current = (try? store.metaInt(key)).flatMap { $0 } ?? 0
            try? store.setMetaInt(key, current + 1)
        }
        previousCharging = reading.isCharging

        if let cycles = reading.cycleCount {
            try? store.setMetaInt(Self.cycleCountKey, Int64(cycles))
        }
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// Reads the `AppleSmartBattery` service, deriving the charge percent from `CurrentCapacity` over
    /// `MaxCapacity` (already a percentage on Apple Silicon, raw mAh on Intel, so the ratio is correct on
    /// both), plus `IsCharging` and `CycleCount`. Returns nil on a machine with no battery service.
    public static func readAppleSmartBattery() -> BatteryReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let current = (dictionary["CurrentCapacity"] as? NSNumber)?.doubleValue else {
                continue
            }
            let maxCapacity = (dictionary["MaxCapacity"] as? NSNumber)?.doubleValue ?? 100
            let percent = maxCapacity > 0 ? current / maxCapacity * 100 : current
            let charging = (dictionary["IsCharging"] as? NSNumber)?.boolValue ?? false
            let cycles = (dictionary["CycleCount"] as? NSNumber)?.intValue
            return BatteryReading(chargePercent: percent, isCharging: charging, cycleCount: cycles)
        }
        return nil
    }
}
