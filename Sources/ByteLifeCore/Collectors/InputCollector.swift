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
    private var clicks: Int64 = 0
    private var scrollUnits: Int64 = 0

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

    /// Counts one mouse-button press. The button and location are never read.
    func addClick() {
        os_unfair_lock_lock(lock)
        clicks &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// Accumulates the absolute scroll travel of one wheel event, in point units. Non-positive units are
    /// dropped so a no-op event never touches the counter.
    func addScroll(units: Int64) {
        guard units > 0 else { return }
        os_unfair_lock_lock(lock)
        scrollUnits &+= units
        os_unfair_lock_unlock(lock)
    }

    /// Atomically reads and zeroes the counters, returning keystrokes, mouse travel in milli-pixels,
    /// clicks, and accumulated scroll units.
    func drain() -> (keystrokes: Int64, mouseMilliPixels: Int64, clicks: Int64, scrollUnits: Int64) {
        os_unfair_lock_lock(lock)
        let keys = keystrokes
        let pixels = mousePixels
        let clickCount = clicks
        let scroll = scrollUnits
        keystrokes = 0
        mousePixels = 0
        clicks = 0
        scrollUnits = 0
        os_unfair_lock_unlock(lock)
        return (keys, Int64((pixels * 1000).rounded()), clickCount, scroll)
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
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        context.addClick()
    case .scrollWheel:
        // Absolute point travel on both axes; the scroll's content and direction are never read.
        let axis1 = abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let axis2 = abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        context.addScroll(units: axis1 + axis2)
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
        // Listen-only interest: keystrokes, mouse motion, mouse-button presses, and scroll wheel. Built
        // by reduction so the type-checker need not solve one nine-term bit-or expression.
        let interested: [CGEventType] = [
            .keyDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
        ]
        let mask = interested.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

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

/// The result of raising the Input Monitoring prompt. `granted` means the grant is present right after
/// the request returned; `promptSuppressed` means the request returned but the grant is still absent,
/// the fingerprint of macOS having already prompted this identity once (later requests silently no-op).
/// The UI reveals the reset affordance on `promptSuppressed`.
public enum PermissionRequestOutcome: Equatable, Sendable {
    case granted
    case promptSuppressed
}

/// The result of the TCC-reset recovery. `reprompted` means tccutil cleared the stored decision and the
/// prompt was re-raised, so the recheck timer observes the grant once the user allows. `failed` carries
/// tccutil's nonzero exit code, which the caller surfaces honestly as an alert.
public enum PermissionResetOutcome: Equatable, Sendable {
    case reprompted
    case failed(exitCode: Int32)
}

/// Counts keystrokes and mouse travel with a listen-only `CGEventTap`, gated on Input Monitoring.
///
/// The tap lives on a dedicated thread running a `CFRunLoop`. A drain timer flushes the shared counters
/// into the store; a slower permission timer catches Input Monitoring being granted or revoked and
/// starts or stops the tap thread accordingly. The permission prompt is never raised automatically:
/// only the UI-invoked `requestPermission()` and its recovery `resetPermissionState()` call
/// `CGRequestListenEventAccess()`.
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
    /// Resets the ListenEvent TCC decision and returns tccutil's exit status. Injectable so the recovery
    /// branching is tested without spawning a process; production runs the real `tccutil reset`.
    private let resetTCC: () -> Int32
    private let drainInterval: DispatchTimeInterval
    private let recheckInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.input")
    private let context = TapContext()

    /// Serializes whole start/stop/recheck transitions so tap and scheduler state never strand under
    /// concurrent calls. Held across blocking waits (never during the availability-field critical
    /// section), so it must not be taken while `lock` is held.
    private let transition = NSLock()
    /// Guards `backingAvailability` and `backingSuspectStale`, so both stay readable cheaply from any
    /// thread.
    private let lock = NSLock()
    private var backingAvailability: Availability
    private var backingSuspectStale = false

    /// Reads the cumulative input-event and attentive-second totals the stale-tap detector diffs across
    /// rechecks. Injected so tests drive the detector without a populated store; production reads today's
    /// running totals from the store.
    private let healthTotals: () -> (inputEvents: Int64, attentiveSeconds: Int64)

    /// Test-only override for tap liveness. Production leaves this nil and creates a real event tap on a
    /// dedicated thread; a test supplies `{ true }` to simulate the stale-tap state (a grant present and
    /// the tap "running" yet delivering nothing) that a real `CGEventTap` cannot reach without a TCC
    /// grant, so the stale-tap detection and recovery paths are exercised deterministically.
    private let tapStarterOverride: (() -> Bool)?

    // Transition-owned state (touched only under `transition`).
    private var started = false
    private var drainScheduler: Scheduler?
    private var recheckScheduler: Scheduler?
    private var tapSession: TapSession?
    /// The pure stale-tap detector. Fed one observation per recheck; latches suspect on a long attentive
    /// run with zero input while the tap claims to run.
    private var tapHealth: TapHealth
    /// The previous recheck's cumulative totals, so the next recheck derives per-interval deltas. Nil
    /// until the first recheck establishes a baseline.
    private var lastHealthTotals: (inputEvents: Int64, attentiveSeconds: Int64)?

    /// Injecting `preflight`/`request` lets tests drive availability without touching TCC; production
    /// uses the real Quartz Event Services checks. `tapHealth` and `healthTotalsProvider` are likewise
    /// injectable so the stale-tap detection is driven deterministically in tests.
    public init(
        store: SampleStore,
        drainInterval: DispatchTimeInterval = .seconds(5),
        recheckInterval: DispatchTimeInterval = .seconds(10),
        preflight: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        request: @escaping () -> Void = { _ = CGRequestListenEventAccess() },
        resetTCC: @escaping () -> Int32 = { TCCReset.run() },
        tapHealth: TapHealth = TapHealth(),
        healthTotalsProvider: (() -> (inputEvents: Int64, attentiveSeconds: Int64))? = nil,
        tapStarter: (() -> Bool)? = nil
    ) {
        self.store = store
        self.drainInterval = drainInterval
        self.recheckInterval = recheckInterval
        self.preflight = preflight
        self.request = request
        self.resetTCC = resetTCC
        self.tapHealth = tapHealth
        self.tapStarterOverride = tapStarter
        // The default provider sums today's input kinds and reads attentive seconds straight from the
        // store totals. Mouse travel is folded into the input sum because attentiveness is HID-idle
        // driven: a user moving only the mouse stays attentive while keys, clicks, and scrolls stay
        // flat, so any mouse travel proves the tap is still delivering and must not be mistaken for a
        // dead tap. Both totals reset together at local midnight; the recheck drops the straddling interval.
        self.healthTotals = healthTotalsProvider ?? {
            let epoch = DayBucket.dayEpoch(for: Date())
            let totals = (try? store.totals(forDayEpoch: epoch)) ?? [:]
            let input = (totals[.inputKeystrokes] ?? 0) + (totals[.inputClicks] ?? 0)
                + (totals[.inputScrollUnits] ?? 0) + (totals[.inputMouseMilliPixels] ?? 0)
            return (input, totals[.screenAttentiveSeconds] ?? 0)
        }
        self.backingAvailability = preflight() ? .running : .needsPermission
    }

    deinit { stop() }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    /// True when the stale-tap detector has flagged the live tap as delivering nothing during attentive
    /// time — the "silent disable race" from a grant gone stale under a changed signature. The panel
    /// reads this to engrave "RE-GRANT — SIGNATURE CHANGED" on MECHANICS instead of the generic
    /// UNCALIBRATED. Guarded by the same lock as `availability`, so any thread reads it cheaply.
    public var tapSuspectStale: Bool {
        lock.lock(); defer { lock.unlock() }
        return backingSuspectStale
    }

    public func start() {
        transition.lock()
        defer { transition.unlock() }
        if started { return }
        started = true
        resetHealth()

        if preflight() {
            setState(ensureTapLive() ? .running : .needsPermission, suspectStale: false)
        } else {
            setState(.needsPermission, suspectStale: false)
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
        resetHealth()
    }

    /// The only path that raises the Input Monitoring prompt. The UI calls this from an explicit user
    /// action. It re-preflights after the request returns and reports the outcome: `granted` when the
    /// grant is now present, or `promptSuppressed` when it is still absent (macOS having already prompted
    /// this identity, so the repeat request silently no-opped). The UI reveals the reset affordance on
    /// `promptSuppressed`.
    @discardableResult
    public func requestPermission() -> PermissionRequestOutcome {
        request()
        return preflight() ? .granted : .promptSuppressed
    }

    /// Recovers from a suppressed prompt: resets the ListenEvent TCC decision via tccutil, then re-raises
    /// the prompt on success so it genuinely fires. Returns `.reprompted` when tccutil succeeded (the
    /// recheck timer picks up the grant once the user allows) or `.failed` with tccutil's nonzero exit
    /// code, which the UI surfaces as an honest alert. Runs the reset synchronously; the UI calls it from
    /// an explicit user action.
    @discardableResult
    public func resetPermissionState() -> PermissionResetOutcome {
        let code = resetTCC()
        guard code == 0 else { return .failed(exitCode: code) }
        request()
        return .reprompted
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
        if counts.clicks > 0 {
            samples.append(Sample(kind: .inputClicks, value: counts.clicks, timestamp: now))
        }
        if counts.scrollUnits > 0 {
            samples.append(Sample(kind: .inputScrollUnits, value: counts.scrollUnits, timestamp: now))
        }
        if !samples.isEmpty { try? store.record(samples) }
    }

    private func recheckPermission() {
        transition.lock()
        defer { transition.unlock() }
        guard started else { return }
        guard preflight() else {
            // Grant explicitly revoked: tear the tap down, forget the run, and drop to needs-permission.
            stopTap()
            resetHealth()
            setState(.needsPermission, suspectStale: false)
            return
        }
        // Grant present: ensure the tap is live. A creation failure keeps us in needs-permission so the
        // next recheck retries; there is no interval to judge until the tap actually runs.
        guard tapSession != nil || ensureTapLive() else {
            setState(.needsPermission, suspectStale: false)
            return
        }
        // The tap reports running. Feed the stale-tap detector this interval's deltas: a long attentive
        // run with zero input is the silent-disable signature of a grant gone stale under a changed
        // signature, so drop to needs-permission with the re-grant tag while keeping the tap alive so a
        // resumed event stream can recover it.
        let suspect = observeTapHealth()
        setState(suspect ? .needsPermission : .running, suspectStale: suspect)
    }

    /// Feeds the stale-tap detector one recheck interval's deltas, derived from the cumulative totals.
    /// Returns whether the tap now looks suspect. The first call only establishes a baseline; a negative
    /// delta (the midnight totals reset) drops the straddling interval rather than feeding a bogus one.
    private func observeTapHealth() -> Bool {
        let current = healthTotals()
        defer { lastHealthTotals = current }
        guard let last = lastHealthTotals else { return tapHealth.isSuspect }
        let inputDelta = current.inputEvents - last.inputEvents
        let attentiveDelta = current.attentiveSeconds - last.attentiveSeconds
        guard inputDelta >= 0, attentiveDelta >= 0 else { return tapHealth.isSuspect }
        return tapHealth.observe(inputEvents: inputDelta, attentiveSeconds: attentiveDelta)
    }

    /// Discards the detector's run, baseline, and any latched suspicion, for a fresh tap lifecycle.
    private func resetHealth() {
        tapHealth.reset()
        lastHealthTotals = nil
        lock.lock(); backingSuspectStale = false; lock.unlock()
    }

    private func setState(_ value: Availability, suspectStale: Bool) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        backingSuspectStale = suspectStale
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    // MARK: - Tap thread (all callers hold `transition`)

    /// Whether the tap is live, honoring the test override when present and otherwise creating the real
    /// tap. The override lets a test simulate a running-but-silent tap without a TCC grant.
    private func ensureTapLive() -> Bool {
        if let tapStarterOverride { return tapStarterOverride() }
        return realStartTap()
    }

    /// Spawns the tap thread and waits for creation to resolve. Returns whether the tap is now live.
    private func realStartTap() -> Bool {
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
