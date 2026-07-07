import Foundation
import CoreServices

/// What an FSEvents notification did to a path. Only create/modify/rename are counted; everything else
/// (removals, permission changes, mount events) is `other` and ignored.
public enum FileTouchKind: Sendable, Equatable {
    case created
    case modified
    case renamed
    case other
}

/// One file event reduced to just what the counter needs: the path (used only to test exclusions, then
/// discarded) and what happened to it. No path is ever stored.
public struct FileTouchEvent: Sendable, Equatable {
    public let path: String
    public let kind: FileTouchKind

    public init(path: String, kind: FileTouchKind) {
        self.path = path
        self.kind = kind
    }
}

/// Pure exclusion and counting rules for file events, factored out so they are tested without FSEvents.
enum FilesTouchedFilter {
    /// The default noise exclusions: the user's `~/Library` (which also contains ByteLife's own store),
    /// any Caches directory, git internals, and the dependency and build directories that churn
    /// constantly without reflecting real work.
    static func defaultExclusions(home: String) -> [String] {
        [
            home + "/Library/",
            "/Caches/",
            "/.git/",
            "/node_modules/",
            "/.build/",
        ]
    }

    /// The number of events worth counting: a create, modify, or rename whose path matches none of the
    /// exclusion substrings. Empty exclusion entries are ignored so they never match everything.
    static func count(_ events: [FileTouchEvent], exclusions: [String]) -> Int {
        events.reduce(0) { total, event in
            guard event.kind != .other else { return total }
            let excluded = exclusions.contains { !$0.isEmpty && event.path.contains($0) }
            return excluded ? total : total + 1
        }
    }
}

/// The top-level FSEvents callback. It resolves the collector from the context info pointer, maps each
/// event's flags to a `FileTouchKind`, and hands the batch to the collector. Per FSEvents' contract the
/// paths are only inspected against exclusions and then dropped.
private let fileEventsCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
    guard let info else { return }
    let collector = Unmanaged<FilesTouchedCollector>.fromOpaque(info).takeUnretainedValue()
    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (cfPaths as? [String]) ?? []
    var events: [FileTouchEvent] = []
    events.reserveCapacity(numEvents)
    for i in 0..<numEvents where i < paths.count {
        events.append(FileTouchEvent(path: paths[i], kind: FilesTouchedCollector.kind(from: eventFlags[i])))
    }
    collector.ingest(events)
}

/// Counts file create/modify/rename events under the home directory into `filesTouched`.
///
/// An FSEvents stream with per-file granularity feeds batches through a pure filter that drops the
/// default noise directories and everything that is not a create, modify, or rename. Only the count is
/// ever recorded; no path is stored. FSEvents coalesces bursts within its latency window, which is the
/// natural debounce. All store writes happen on the stream's own dispatch queue; tests bypass FSEvents
/// entirely and call `ingest(_:now:)` with crafted events.
public final class FilesTouchedCollector: Collector, @unchecked Sendable {
    public let id = "files"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: SampleStore
    private let home: String
    private let exclusions: [String]
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "life.byte.files")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var stream: FSEventStreamRef?

    /// `appDataDir`, when given, is excluded explicitly; in practice it lives under `~/Library` and is
    /// already covered. Injecting `home` lets tests exercise the exclusions against a synthetic tree.
    public init(
        store: SampleStore,
        home: String = NSHomeDirectory(),
        appDataDir: String? = nil,
        latency: CFTimeInterval = 2.0
    ) {
        self.store = store
        self.home = home
        self.latency = latency
        self.exclusions = FilesTouchedFilter.defaultExclusions(home: home)
            + (appDataDir.map { [$0] } ?? [])
    }

    deinit { stop() }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    /// Maps an FSEvents flag word to a `FileTouchKind`, preferring create over rename over modify when
    /// several bits are set. Classification only steers reporting; each of the three counts as one.
    static func kind(from flags: FSEventStreamEventFlags) -> FileTouchKind {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 { return .created }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 { return .renamed }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 { return .modified }
        return .other
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileEventsCallback,
            &context,
            [home] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            backingAvailability = .sourceMissing
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            backingAvailability = .sourceMissing
            return
        }
        stream = created
        backingAvailability = .running
    }

    public func stop() {
        lock.lock()
        let existing = stream
        stream = nil
        lock.unlock()
        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }

    /// Filters a batch and books the counted create/modify/rename events as an additive `filesTouched`
    /// delta. Runs on the stream's queue in production; tests call it directly.
    func ingest(_ events: [FileTouchEvent], now: Date = Date()) {
        let counted = FilesTouchedFilter.count(events, exclusions: exclusions)
        guard counted > 0 else { return }
        try? store.record([Sample(kind: .filesTouched, value: Int64(counted), timestamp: now)])
    }
}
