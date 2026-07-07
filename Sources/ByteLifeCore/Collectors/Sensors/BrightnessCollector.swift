import Foundation
import CoreGraphics

/// Books the main display's backlight brightness per minute into the `displayBrightness` gauge (per mille).
///
/// A 60 s tick reads an injectable brightness fraction (0…1). Production resolves it through the private
/// DisplayServices framework by `dlopen`/`dlsym` on `DisplayServicesGetBrightness`, with a graceful nil
/// path when the framework or symbol is unavailable or the call fails, so the collector degrades to
/// `sourceMissing` honestly. All mutable state is confined to `queue`; tests inject the reader and clock
/// and call `tick()` directly.
public final class BrightnessCollector: Collector, @unchecked Sendable {
    public let id = "brightness"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let readBrightness: () -> Double?
    private let now: () -> Date
    private let tickInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.brightness")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?

    public init(
        store: SampleStore,
        tickInterval: DispatchTimeInterval = .seconds(60),
        now: @escaping () -> Date = Date.init,
        readBrightness: @escaping () -> Double? = BrightnessCollector.displayServicesBrightness
    ) {
        self.store = store
        self.tickInterval = tickInterval
        self.now = now
        self.readBrightness = readBrightness
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

    /// One tick: sample the brightness fraction into the per-mille gauge, or degrade to `sourceMissing`
    /// when it cannot be read. Runs on `queue`; tests call it directly.
    func tick() {
        guard let fraction = readBrightness() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)
        let clamped = min(1, max(0, fraction))
        let bucket = DayBucket(date: now())
        try? store.recordGauge(
            dayEpoch: bucket.dayEpoch, minute: bucket.minute,
            gauge: GaugeName.displayBrightness, value: Int64((clamped * 1000).rounded())
        )
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// Reads the main display's brightness fraction (0…1) via the private DisplayServices framework,
    /// resolved by `dlopen`/`dlsym`. Returns nil when the framework, the symbol, or the call is
    /// unavailable, so the collector degrades honestly.
    public static func displayServicesBrightness() -> Double? {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        let getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        var brightness: Float = 0
        guard getBrightness(CGMainDisplayID(), &brightness) == 0,
              brightness >= 0, brightness <= 1 else { return nil }
        return Double(brightness)
    }
}
