import Foundation
import AppKit

/// Books system wakes and boots, two permission-free signals.
///
/// Each `NSWorkspace.didWakeNotification` books one `systemWakes`. Boots are detected at launch by reading
/// the kernel boot time (`sysctl kern.boottime`) and comparing it to the value stored last launch under
/// the meta key `wakes.bootTime`: a changed boot time means the machine rebooted since, so one `systemBoots`
/// is booked and the new value stored. The first-ever launch only baselines. A relaunch across a sleep/wake
/// leaves the boot time unchanged, so a wake is never miscounted as a boot. Availability is always running,
/// since neither primitive needs a permission. All mutable state is confined to `queue`; tests inject the
/// boot-time reader and clock and call `handleWake()` / `checkBoot()` directly.
public final class WakesCollector: Collector, @unchecked Sendable {
    public let id = "wakes"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?
    public var availability: Availability { .running }

    /// The meta key holding the kernel boot time seen at the previous launch.
    public static let bootTimeKey = "wakes.bootTime"

    private let store: SampleStore
    private let readBootTime: () -> Int64?
    private let now: () -> Date
    private let queue = DispatchQueue(label: "life.byte.wakes")

    private let lock = NSLock()
    private var running = false
    private var observer: NSObjectProtocol?

    public init(
        store: SampleStore,
        now: @escaping () -> Date = Date.init,
        readBootTime: @escaping () -> Int64? = WakesCollector.kernelBootTime
    ) {
        self.store = store
        self.now = now
        self.readBootTime = readBootTime
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        let alreadyRunning = running
        running = true
        lock.unlock()
        guard !alreadyRunning else { return }

        queue.sync { self.checkBoot() }
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.handleWake() }
        }
        lock.lock(); observer = token; lock.unlock()
    }

    public func stop() {
        lock.lock()
        running = false
        let token = observer
        observer = nil
        lock.unlock()
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    /// Books one wake. Runs on `queue`; tests call it directly.
    func handleWake() {
        try? store.record([Sample(kind: .systemWakes, value: 1, timestamp: now())])
    }

    /// Books one boot when the kernel boot time changed since the last launch, then stores the current
    /// value. Runs on `queue`; tests call it directly.
    func checkBoot() {
        guard let current = readBootTime() else { return }
        let previous = (try? store.metaInt(Self.bootTimeKey)).flatMap { $0 }
        if SensorSignal.rebooted(previousBootTime: previous, current: current) {
            try? store.record([Sample(kind: .systemBoots, value: 1, timestamp: now())])
        }
        try? store.setMetaInt(Self.bootTimeKey, current)
    }

    /// The kernel boot time in whole Unix seconds via `sysctl kern.boottime`, or nil when the call fails.
    public static func kernelBootTime() -> Int64? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return nil }
        return Int64(boot.tv_sec)
    }
}
