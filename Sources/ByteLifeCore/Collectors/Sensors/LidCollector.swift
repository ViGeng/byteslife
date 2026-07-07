import Foundation
import IOKit
import IOKit.hid

/// Books lid open transitions and, where the sensor exists, the lid opening angle.
///
/// A 5 s poll reads the clamshell state from `IOPMrootDomain`'s `AppleClamshellState` property (true when
/// the lid is closed). A closed→open edge books one `lidOpens`; the counter's first sample only baselines.
/// The opening ANGLE is best-effort: recent MacBooks expose a HID lid-angle sensor (usage page 0x20,
/// usage 0x8A) that this collector samples once per minute into the `lidAngle` gauge when readable, and
/// simply skips when the sensor is absent, so the open/close counter keeps working on machines without it.
/// Availability follows the clamshell property alone: `running` while it reads, `sourceMissing` on a
/// desktop that has no lid. All mutable state is confined to `queue`; tests inject the readers and clock
/// and call `poll()` directly.
public final class LidCollector: Collector, @unchecked Sendable {
    public let id = "lid"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let readClamshellClosed: () -> Bool?
    private let readLidAngle: () -> Double?
    private let now: () -> Date
    private let pollInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.lid")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?

    // Confined to `queue` (or driven directly by single-threaded tests).
    private var previousOpen: Bool?
    private var lastAngleMinute: Int32?

    /// Injecting the readers and clock lets tests drive transitions deterministically; production reads the
    /// live clamshell property and the HID lid-angle sensor.
    public init(
        store: SampleStore,
        pollInterval: DispatchTimeInterval = .seconds(5),
        now: @escaping () -> Date = Date.init,
        readClamshellClosed: @escaping () -> Bool? = LidCollector.clamshellClosed,
        readLidAngle: @escaping () -> Double? = LidAngleSensor.currentAngle
    ) {
        self.store = store
        self.pollInterval = pollInterval
        self.now = now
        self.readClamshellClosed = readClamshellClosed
        self.readLidAngle = readLidAngle
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
        let scheduler = Scheduler(queue: queue, interval: pollInterval) { [weak self] in self?.poll() }
        lock.lock(); self.scheduler = scheduler; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        lock.unlock()
    }

    /// One poll: read the clamshell state, book a lid open on a closed→open edge, and sample the angle
    /// gauge once per minute where the sensor reads. A machine with no lid property degrades to
    /// `sourceMissing`. Runs on `queue`; tests call it directly.
    func poll() {
        guard let closed = readClamshellClosed() else {
            setAvailability(.sourceMissing)
            return
        }
        setAvailability(.running)

        let open = !closed
        if SensorSignal.rose(previous: previousOpen, current: open) {
            try? store.record([Sample(kind: .lidOpens, value: 1, timestamp: now())])
        }
        previousOpen = open

        let bucket = DayBucket(date: now())
        if bucket.minute != lastAngleMinute, let angle = readLidAngle() {
            try? store.recordGauge(
                dayEpoch: bucket.dayEpoch, minute: bucket.minute,
                gauge: GaugeName.lidAngle, value: Int64(angle.rounded())
            )
            lastAngleMinute = bucket.minute
        }
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// Reads `IOPMrootDomain`'s `AppleClamshellState` (true = lid closed), or nil when the machine has no
    /// such property (a desktop with no lid), so the collector degrades honestly.
    public static func clamshellClosed() -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let value = property.takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}

/// Best-effort reader for the HID lid-angle sensor present on recent MacBooks (sensor usage page 0x20,
/// usage 0x8A). It matches the device through `IOHIDManager` and reads the angle element's current value,
/// returning nil when the sensor is absent or has delivered no report, so the gauge is simply not written
/// on machines without it. The reader never blocks on a run loop; an unreadable sensor is a silent skip.
public enum LidAngleSensor {
    private static let usagePage = 0x20
    private static let usage = 0x8A

    /// The current lid opening angle in degrees, or nil when the sensor cannot be read.
    public static func currentAngle() -> Double? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: usagePage,
            kIOHIDDeviceUsageKey: usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else { return nil }

        let elementMatch: [String: Any] = [
            kIOHIDElementUsagePageKey: usagePage,
            kIOHIDElementUsageKey: usage,
        ]
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device, elementMatch as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return nil }

        for element in elements {
            let angle: Int? = withUnsafeTemporaryAllocation(
                of: Unmanaged<IOHIDValue>.self, capacity: 1
            ) { buffer in
                guard IOHIDDeviceGetValue(device, element, buffer.baseAddress!) == kIOReturnSuccess
                else { return nil }
                return IOHIDValueGetIntegerValue(buffer[0].takeUnretainedValue())
            }
            if let angle, angle > 0, angle <= 360 { return Double(angle) }
        }
        return nil
    }
}
