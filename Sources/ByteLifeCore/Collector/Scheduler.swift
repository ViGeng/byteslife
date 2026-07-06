import Foundation

/// A repeating timer wrapper used by the polling collectors (network, disk, screen).
///
/// The handler fires on a caller-provided serial queue, so a collector can share the same queue it
/// guards its state with and never needs cross-queue synchronization inside the handler. `start()`
/// and `stop()` are idempotent and safe to call from any thread; an internal lock guards the timer
/// slot, so a redundant `start()` never spins up a second source.
public final class Scheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private let interval: DispatchTimeInterval
    private let leeway: DispatchTimeInterval
    private let handler: @Sendable () -> Void

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    public init(
        queue: DispatchQueue,
        interval: DispatchTimeInterval,
        leeway: DispatchTimeInterval = .milliseconds(200),
        handler: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.interval = interval
        self.leeway = leeway
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Starts the repeating timer. First fire lands one `interval` from now. A no-op if already running.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        source.setEventHandler(handler: handler)
        source.resume()
        timer = source
    }

    /// Cancels the timer. A no-op if not running.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}
