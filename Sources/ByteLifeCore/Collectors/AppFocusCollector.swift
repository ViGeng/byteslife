import Foundation
import AppKit

/// Books foreground attention per application into the `focus` table.
///
/// A sampling estimator: every poll (5 s in production) credits the whole interval to whichever app is
/// frontmost at that instant, the standard time-use approximation whose accuracy is the poll cadence.
/// Credited seconds accumulate per bundle id and flush to the store once per minute, so the table sees
/// a steady trickle of accumulating UPSERTs rather than a write per poll. A failed flush re-stashes its
/// seconds so nothing is lost. Availability is always running because `NSWorkspace.frontmostApplication`
/// needs no permission. All mutable state is confined to `queue`; tests call `poll()` and `flush()`
/// directly with an injected clock and frontmost reader.
public final class AppFocusCollector: Collector, @unchecked Sendable {
    public let id = "focus"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?
    public var availability: Availability { .running }

    private let store: SampleStore
    private let frontmostBundleID: () -> String?
    private let now: () -> Date
    private let pollInterval: DispatchTimeInterval
    private let secondsPerPoll: Int64
    private let pollsPerFlush: Int
    private let queue = DispatchQueue(label: "life.byte.focus")

    private let lock = NSLock()
    private var scheduler: Scheduler?

    // Confined to `queue` (or driven directly by single-threaded tests).
    private var pending: [String: Int64] = [:]
    private var pollsSinceFlush = 0

    /// Injecting the reader, clock, and cadence lets tests drive accumulation deterministically;
    /// production reads the live frontmost bundle id every five seconds and flushes each minute.
    public init(
        store: SampleStore,
        pollInterval: DispatchTimeInterval = .seconds(5),
        secondsPerPoll: Int64 = 5,
        pollsPerFlush: Int = 12,
        now: @escaping () -> Date = Date.init,
        frontmostBundleID: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.store = store
        self.pollInterval = pollInterval
        self.secondsPerPoll = secondsPerPoll
        self.pollsPerFlush = max(1, pollsPerFlush)
        self.now = now
        self.frontmostBundleID = frontmostBundleID
    }

    deinit { stop() }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard scheduler == nil else { return }
        let scheduler = Scheduler(queue: queue, interval: pollInterval) { [weak self] in self?.poll() }
        self.scheduler = scheduler
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        let running = scheduler != nil
        scheduler?.stop()
        scheduler = nil
        lock.unlock()
        // Flush the tail so a stop never strands accrued attention. Skip if never started.
        guard running else { return }
        queue.sync { self.flush() }
    }

    /// One sample: credit the poll interval to the frontmost app, then flush on the minute. Runs on
    /// `queue`; tests call it directly.
    func poll() {
        if let bundle = frontmostBundleID(), !bundle.isEmpty {
            pending[bundle, default: 0] += secondsPerPoll
        }
        pollsSinceFlush += 1
        if pollsSinceFlush >= pollsPerFlush { flush() }
    }

    /// Writes accumulated per-app seconds to the store, bucketed at the current day. Runs on `queue`;
    /// tests call it directly. A write failure re-stashes the seconds so the next flush retries them.
    func flush() {
        pollsSinceFlush = 0
        guard !pending.isEmpty else { return }
        let dayEpoch = DayBucket.dayEpoch(for: now())
        let snapshot = pending
        pending.removeAll(keepingCapacity: true)
        for (bundle, seconds) in snapshot {
            do {
                try store.recordFocus(dayEpoch: dayEpoch, bundleId: bundle, seconds: seconds)
            } catch {
                pending[bundle, default: 0] += seconds
            }
        }
    }
}
