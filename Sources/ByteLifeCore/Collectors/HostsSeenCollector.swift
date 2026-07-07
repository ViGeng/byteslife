import Foundation
import CryptoKit

/// Extracts remote host identities from `nettop -m route -x -L 1` output. Per-process mode (`-P`) carries
/// no host, so route mode is the reliable per-host source: each data row is one remote route, the host in
/// the field after the leading timestamp. Pure and tested against captured output.
enum NettopRouteParser {
    /// The distinct remote hosts in first-seen order. Skips the header, the `default -> ... -> gateway`
    /// summary and anything else with a space or an arrow, wildcards, and blank fields.
    static func hosts(from output: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let host = fields[1].trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty,
                  !host.contains("->"),
                  !host.contains("*"),
                  !host.contains(" ") else { continue }
            if seen.insert(host).inserted { result.append(host) }
        }
        return result
    }
}

/// Salts and hashes a hostname so only an opaque, per-install identifier is ever stored. The salt makes
/// the hashes non-comparable across machines and non-reversible without it.
enum HostHasher {
    /// SHA-256 over `salt|host`, truncated to 16 hex characters to match the receipt's hash grammar.
    static func hash(host: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + "|" + host).utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// Records the count of distinct remote hosts contacted per day, as salted hashes only.
///
/// A 60 s poll runs `nettop -m route -x -L 1`, parses the remote hosts, and marks each into the per-day
/// `hosts_seen` dedup set under a per-install random salt. The metric is the distinct count; no hostname
/// is ever stored. The collector degrades to `sourceMissing` after several consecutive polls where
/// nettop could not be run or produced nothing parseable, and never crashes on unexpected output. All
/// work runs on `queue`; tests inject the runner and call `tick()` directly.
public final class HostsSeenCollector: Collector, @unchecked Sendable {
    public let id = "hosts"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private static let saltKey = "hosts.salt"

    private let store: SampleStore
    private let runNettop: () -> String?
    private let now: () -> Date
    private let interval: DispatchTimeInterval
    private let failureThreshold: Int
    private let queue = DispatchQueue(label: "life.byte.hosts")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?

    // Confined to `queue`.
    private var consecutiveFailures = 0

    /// Injecting the runner and clock lets tests drive the collector without spawning nettop; production
    /// runs the real command every minute.
    public init(
        store: SampleStore,
        interval: DispatchTimeInterval = .seconds(60),
        failureThreshold: Int = 3,
        now: @escaping () -> Date = Date.init,
        runNettop: @escaping () -> String? = HostsSeenCollector.runRouteQuery
    ) {
        self.store = store
        self.interval = interval
        self.failureThreshold = max(1, failureThreshold)
        self.now = now
        self.runNettop = runNettop
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
        let scheduler = Scheduler(queue: queue, interval: interval) { [weak self] in self?.tick() }
        lock.lock(); self.scheduler = scheduler; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        lock.unlock()
    }

    /// One polling cycle: run nettop, parse the hosts, and mark each under the install salt. A run that
    /// fails to produce parseable hosts advances the failure counter and, past the threshold, degrades to
    /// `sourceMissing`; any successful parse resets it to running. Runs on `queue`; tests call it directly.
    func tick() {
        guard let output = runNettop(), !output.isEmpty else {
            registerFailure()
            return
        }
        let hosts = NettopRouteParser.hosts(from: output)
        guard !hosts.isEmpty else {
            registerFailure()
            return
        }

        consecutiveFailures = 0
        setAvailability(.running)

        let salt = currentSalt()
        let dayEpoch = DayBucket.dayEpoch(for: now())
        for host in hosts {
            _ = try? store.markHostSeen(dayEpoch: dayEpoch, hash: HostHasher.hash(host: host, salt: salt))
        }
    }

    private func registerFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold { setAvailability(.sourceMissing) }
    }

    /// The per-install salt, generated and persisted on first use. Never the hostname.
    private func currentSalt() -> String {
        if let existing = (try? store.metaString(Self.saltKey)) ?? nil, !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        try? store.setMetaString(Self.saltKey, generated)
        return generated
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }

    /// Runs `nettop -m route -x -L 1` once and returns its stdout, or nil if it could not be run or exited
    /// non-zero. `-L 1` bounds the output to a single sample, so reading to end then waiting cannot block.
    public static func runRouteQuery() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-m", "route", "-x", "-L", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
