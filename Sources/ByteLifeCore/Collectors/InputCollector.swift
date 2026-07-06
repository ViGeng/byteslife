import Foundation
import CoreGraphics
import os

/// Shared, lock-guarded counters written by the event-tap C callback and drained by the collector's
/// timer. The lock is heap-allocated (not an inline stored property) so its address is stable across
/// the callback thread and the drain thread. The callback does microseconds of work: it never reads a
/// keycode or character, only bumps these totals.
final class TapContext {
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var keystrokes: Int64 = 0
    private var mousePixels: Double = 0

    /// Set once on the tap thread right after the tap is created, then read there in the callback to
    /// re-enable a tap the system disabled. Not touched from other threads.
    var tap: CFMachPort?

    init() { lock.initialize(to: os_unfair_lock()) }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func addKeystroke() {
        os_unfair_lock_lock(lock)
        keystrokes &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// Accumulates the straight-line travel of one mouse event. `hypot` is computed outside the lock so
    /// the critical section stays trivial.
    func addMouse(deltaX: Double, deltaY: Double) {
        let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()
        os_unfair_lock_lock(lock)
        mousePixels += distance
        os_unfair_lock_unlock(lock)
    }

    /// Atomically reads and zeroes the counters, returning keystrokes and mouse travel in milli-pixels.
    func drain() -> (keystrokes: Int64, mouseMilliPixels: Int64) {
        os_unfair_lock_lock(lock)
        let keys = keystrokes
        let pixels = mousePixels
        keystrokes = 0
        mousePixels = 0
        os_unfair_lock_unlock(lock)
        return (keys, Int64((pixels * 1000).rounded()))
    }
}

/// The top-level C callback the event tap invokes for each event. It resolves the `TapContext` from
/// the refcon, bumps a counter, and returns the event unchanged so input is never altered or blocked.
private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .keyDown:
        context.addKeystroke()
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        context.addMouse(
            deltaX: event.getDoubleValueField(.mouseEventDeltaX),
            deltaY: event.getDoubleValueField(.mouseEventDeltaY)
        )
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = context.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

/// One run of the event tap on its own run-loop thread. Keeping the tap's mutable state here rather
/// than on the collector lets the thread closure capture only this session (never `self`), so the
/// collector can deinit while a tap is still tearing down. `ready` is signaled once tap creation has
/// resolved (success or failure) and the run loop is published; `exited` is signaled after the run
/// loop returns and the tap is disabled, so the collector can wait for full teardown before ever
/// starting another tap and two tap threads never overlap.
private final class TapSession {
    let ready = DispatchSemaphore(value: 0)
    let exited = DispatchSemaphore(value: 0)

    private let context: TapContext
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var created = false

    init(context: TapContext) { self.context = context }

    /// Whether the tap was created. Meaningful only after `ready.wait()`.
    func didCreate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return created
    }

    /// Runs on the dedicated tap thread: creates the tap, pumps its run loop, then tears it down.
    func run() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            // Secure Input or a transient denial can fail creation even after preflight passed. Leave
            // `created` false and signal `ready` so the collector drops this session and retries later.
            ready.signal()
            return
        }
        context.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock(); runLoop = rl; created = true; lock.unlock()
        ready.signal()

        CFRunLoopRun()

        // Reached only after stop() stops the run loop.
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(rl, source, .commonModes)
        context.tap = nil
        exited.signal()
    }

    /// Stops the run loop and waits for the thread to fully unwind. `ready` was already consumed by
    /// `startTap()` before this session became reachable (failed sessions are dropped and `transition`
    /// serializes start/stop), so the run loop is published by the time this runs — waiting on `ready`
    /// again here would deadlock.
    func stop() {
        lock.lock(); let rl = runLoop; runLoop = nil; lock.unlock()
        guard let rl else { return }
        CFRunLoopStop(rl)
        // Generous bound: the run loop returns almost immediately once stopped.
        _ = exited.wait(timeout: .now() + .seconds(5))
    }
}

/// Counts keystrokes and mouse travel with a listen-only `CGEventTap`, gated on Input Monitoring.
///
/// The tap lives on a dedicated thread running a `CFRunLoop`. A drain timer flushes the shared counters
/// into the store; a slower permission timer catches Input Monitoring being granted or revoked and
/// starts or stops the tap thread accordingly. The permission prompt is never raised automatically:
/// only `requestPermission()`, invoked by the UI, calls `CGRequestListenEventAccess()`.
///
/// `stop()` (also called from `deinit`) is the only path that releases the tap; the tap thread never
/// retains the collector, so releasing the collector always runs a clean teardown.
public final class InputCollector: Collector, @unchecked Sendable {
    public let id = "input"
    public let family: MetricFamily = .input
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let preflight: () -> Bool
    private let request: () -> Void
    private let drainInterval: DispatchTimeInterval
    private let recheckInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.input")
    private let context = TapContext()

    /// Serializes whole start/stop/recheck transitions so tap and scheduler state never strand under
    /// concurrent calls. Held across blocking waits (never during the availability-field critical
    /// section), so it must not be taken while `lock` is held.
    private let transition = NSLock()
    /// Guards `backingAvailability` only, so `availability` stays readable from any thread cheaply.
    private let lock = NSLock()
    private var backingAvailability: Availability

    // Transition-owned state (touched only under `transition`).
    private var started = false
    private var drainScheduler: Scheduler?
    private var recheckScheduler: Scheduler?
    private var tapSession: TapSession?

    /// Injecting `preflight`/`request` lets tests drive availability without touching TCC; production
    /// uses the real Quartz Event Services checks.
    public init(
        store: SampleStore,
        drainInterval: DispatchTimeInterval = .seconds(5),
        recheckInterval: DispatchTimeInterval = .seconds(10),
        preflight: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        request: @escaping () -> Void = { _ = CGRequestListenEventAccess() }
    ) {
        self.store = store
        self.drainInterval = drainInterval
        self.recheckInterval = recheckInterval
        self.preflight = preflight
        self.request = request
        self.backingAvailability = preflight() ? .running : .needsPermission
    }

    deinit { stop() }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    public func start() {
        transition.lock()
        defer { transition.unlock() }
        if started { return }
        started = true

        if preflight() {
            setAvailability(startTap() ? .running : .needsPermission)
        } else {
            setAvailability(.needsPermission)
        }

        let drain = Scheduler(queue: queue, interval: drainInterval) { [weak self] in self?.drain() }
        let recheck = Scheduler(queue: queue, interval: recheckInterval) { [weak self] in self?.recheckPermission() }
        drainScheduler = drain
        recheckScheduler = recheck
        drain.start()
        recheck.start()
    }

    public func stop() {
        transition.lock()
        defer { transition.unlock() }
        if !started { return }
        started = false
        drainScheduler?.stop()
        recheckScheduler?.stop()
        drainScheduler = nil
        recheckScheduler = nil
        stopTap()
    }

    /// The only path that raises the Input Monitoring prompt. The UI calls this from an explicit user action.
    public func requestPermission() {
        request()
    }

    // MARK: - Drain and permission

    private func drain() {
        let counts = context.drain()
        var samples: [Sample] = []
        let now = Date()
        if counts.keystrokes > 0 {
            samples.append(Sample(kind: .inputKeystrokes, value: counts.keystrokes, timestamp: now))
        }
        if counts.mouseMilliPixels > 0 {
            samples.append(Sample(kind: .inputMouseMilliPixels, value: counts.mouseMilliPixels, timestamp: now))
        }
        if !samples.isEmpty { try? store.record(samples) }
    }

    private func recheckPermission() {
        transition.lock()
        defer { transition.unlock() }
        guard started else { return }
        let granted = preflight()
        if granted {
            // Start the tap if it is not live yet; a creation failure keeps us in .needsPermission so
            // the next recheck retries.
            let live = tapSession != nil || startTap()
            setAvailability(live ? .running : .needsPermission)
        } else {
            stopTap()
            setAvailability(.needsPermission)
        }
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    // MARK: - Tap thread (all callers hold `transition`)

    /// Spawns the tap thread and waits for creation to resolve. Returns whether the tap is now live.
    private func startTap() -> Bool {
        if tapSession != nil { return true }
        let session = TapSession(context: context)
        tapSession = session
        let thread = Thread { session.run() }
        thread.name = "life.byte.input.tap"
        thread.start()

        session.ready.wait()
        if session.didCreate() { return true }
        // Creation failed after preflight passed: drop the session so a later recheck retries.
        tapSession = nil
        return false
    }

    /// Tears down the live tap, waiting for its thread to unwind so tap threads never overlap.
    private func stopTap() {
        guard let session = tapSession else { return }
        tapSession = nil
        session.stop()
    }
}
