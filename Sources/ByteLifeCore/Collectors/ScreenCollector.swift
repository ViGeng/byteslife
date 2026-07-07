import Foundation
import AppKit

/// Tracks attentive screen time with an idle/sleep/lock state machine.
///
/// The resilient floor is the idle timer: every tick reads seconds-since-last-input and treats the
/// user as inactive past `idleThreshold`. On top of that, NSWorkspace sleep/wake and session
/// notifications plus the undocumented lock/unlock distributed notifications flip attentiveness
/// immediately at transitions. Time is accrued on a monotonic clock (`CLOCK_UPTIME_RAW`) that stops
/// during system sleep, so an overnight sleep gap is never counted. Each flush records whole attentive
/// seconds bucketed at the current wall-clock time, so a session spanning midnight splits across days.
///
/// All mutable state is confined to `queue`: the scheduler tick runs on it, and every notification
/// handler hops onto it. Availability is always running because none of these primitives need a permission.
public final class ScreenCollector: Collector, @unchecked Sendable {
    public let id = "screen"
    public let family: MetricFamily = .screen
    public var onAvailabilityChange: ((Availability) -> Void)?
    public var availability: Availability { .running }

    private let store: SampleStore
    private let idleThreshold: TimeInterval
    private let tickInterval: DispatchTimeInterval
    private let idleSeconds: () -> Double
    private let clock: () -> UInt64
    private let now: () -> Date
    private let queue = DispatchQueue(label: "life.byte.screen")

    /// Serializes whole start/stop transitions so scheduler and observers never strand under
    /// concurrent calls. Held across `queue.sync` and observer registration, so it must not be taken
    /// while `lock` is held (`registerObservers` acquires `lock`).
    private let transition = NSLock()
    /// Guards the `scheduler`/`observers` fields for cheap cross-thread access.
    private let lock = NSLock()
    private var scheduler: Scheduler?
    private var observers: [NSObjectProtocol] = []

    // State touched only on `queue` (or directly by tests, which are single-threaded).
    private var attentive = false
    private var lastMark: UInt64 = 0
    private var pendingNanos: UInt64 = 0
    private var systemAsleep = false
    private var screenAsleep = false
    private var screenLocked = false
    private var sessionActive = true

    public init(
        store: SampleStore,
        idleThreshold: TimeInterval = 300,
        tickInterval: DispatchTimeInterval = .seconds(30),
        idleSeconds: @escaping () -> Double = IdleTime.idleSeconds,
        clock: @escaping () -> UInt64 = ScreenCollector.uptimeNanos,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.idleThreshold = idleThreshold
        self.tickInterval = tickInterval
        self.idleSeconds = idleSeconds
        self.clock = clock
        self.now = now
    }

    deinit { stop() }

    /// Monotonic nanoseconds that do not advance while the system is asleep.
    public static func uptimeNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    public func start() {
        transition.lock()
        defer { transition.unlock() }
        lock.lock()
        let alreadyRunning = scheduler != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let scheduler = Scheduler(queue: queue, interval: tickInterval) { [weak self] in self?.tick() }
        lock.lock(); self.scheduler = scheduler; lock.unlock()

        queue.sync { self.prime() }
        registerObservers()
        scheduler.start()
    }

    public func stop() {
        transition.lock()
        defer { transition.unlock() }
        lock.lock()
        let running = scheduler != nil
        scheduler?.stop()
        scheduler = nil
        let tokens = observers
        observers = []
        lock.unlock()
        guard running else { return }

        let center = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for token in tokens {
            center.removeObserver(token)
            distributed.removeObserver(token)
        }
    }

    // MARK: - State machine (runs on `queue`; tests call directly)

    /// Establishes the initial mark and attentiveness. Must run on `queue`.
    func prime() {
        lastMark = clock()
        recomputeAttentive(idle: idleSeconds())
    }

    /// One idle tick: flush time accrued under the prior state, then re-evaluate from the idle timer.
    func tick() {
        flush()
        recomputeAttentive(idle: idleSeconds())
    }

    /// Accrues monotonic time since the last mark (counted only while attentive), then records any
    /// whole attentive seconds bucketed at the current wall-clock time. Sub-second remainder carries
    /// forward so nothing is lost or double counted.
    private func flush() {
        let current = clock()
        let elapsed = current &- lastMark
        lastMark = current
        if attentive { pendingNanos &+= elapsed }

        let wholeSeconds = pendingNanos / 1_000_000_000
        guard wholeSeconds > 0 else { return }
        pendingNanos -= wholeSeconds * 1_000_000_000
        try? store.record([Sample(
            kind: .screenAttentiveSeconds,
            value: Int64(wholeSeconds),
            timestamp: now()
        )])
    }

    /// Re-evaluates attentiveness and, on a rising edge (inactive to attentive), books one attention
    /// session. `attentive` starts false, so the first attentive evaluation after start counts as the
    /// session it opens. Runs on `queue`.
    private func recomputeAttentive(idle: Double) {
        let wasAttentive = attentive
        attentive = !systemAsleep
            && !screenAsleep
            && !screenLocked
            && sessionActive
            && idle < idleThreshold
        if attentive, !wasAttentive {
            try? store.record([Sample(kind: .attentionSessions, value: 1, timestamp: now())])
        }
    }

    /// Handles a screen unlock: books one unlock, then clears the lock flag through the normal
    /// flush-mutate-recompute path so the interval before the unlock is settled first. Runs on `queue`.
    func handleUnlock() {
        try? store.record([Sample(kind: .screenUnlocks, value: 1, timestamp: now())])
        setFlag { $0.screenLocked = false }
    }

    // MARK: - Notifications

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func workspace(_ name: Notification.Name, _ body: @escaping () -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { body() }
            }
        }
        func lockNote(_ name: String, _ body: @escaping () -> Void) -> NSObjectProtocol {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { body() }
            }
        }

        var tokens: [NSObjectProtocol] = []
        tokens.append(workspace(NSWorkspace.willSleepNotification) { [weak self] in self?.setFlag { $0.systemAsleep = true } })
        tokens.append(workspace(NSWorkspace.didWakeNotification) { [weak self] in self?.setFlag { $0.systemAsleep = false } })
        tokens.append(workspace(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.setFlag { $0.screenAsleep = true } })
        tokens.append(workspace(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.setFlag { $0.screenAsleep = false } })
        tokens.append(workspace(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.setFlag { $0.sessionActive = false } })
        tokens.append(workspace(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.setFlag { $0.sessionActive = true } })
        tokens.append(lockNote("com.apple.screenIsLocked") { [weak self] in self?.setFlag { $0.screenLocked = true } })
        tokens.append(lockNote("com.apple.screenIsUnlocked") { [weak self] in self?.handleUnlock() })

        lock.lock()
        observers = tokens
        lock.unlock()
    }

    /// Flushes time up to this instant under the prior state, applies the flag mutation, then
    /// re-evaluates attentiveness. Runs on `queue`.
    private func setFlag(_ mutate: (ScreenCollector) -> Void) {
        flush()
        mutate(self)
        recomputeAttentive(idle: idleSeconds())
    }
}
