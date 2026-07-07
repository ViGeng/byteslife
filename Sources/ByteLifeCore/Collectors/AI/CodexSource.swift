import Foundation

/// Watches `~/.codex/sessions` (injectable for tests) for Codex CLI `rollout-*.jsonl` transcripts,
/// which nest under `year/month/day` date directories. It tails new lines, converts Codex's CUMULATIVE
/// per-session `token_count` snapshots into per-event deltas (current cumulative minus the previous
/// snapshot, clamped at zero), deduplicates against the store's `ai_seen` ledger, and records the
/// resulting additive samples through the store's atomic `ingest`.
///
/// All mutable state lives behind one serial `queue`. Directory watchers are installed at every level of
/// the date tree so newly created year/month/day folders and rollout files are rediscovered. Only a file
/// modified within `AISourceWatch.recencyWindow` earns a persistent per-file vnode watcher (which drives
/// its tailing and tears itself down when the file is deleted or renamed); an older file gets none and is
/// re-tailed on each discovery pass only when a cheap `stat` shows it grew, so a machine with thousands of
/// historical rollouts stays well under its file-descriptor limit. Per file,
/// the byte offset, inode, the last-seen cumulative totals, and the event ordinal all persist in store
/// meta, so restarts resume exactly where they left off and every watcher file descriptor closes in its
/// cancel handler.
public final class CodexSource: AIUsageSource, @unchecked Sendable {
    public let id = "ai.codex"
    public var displayName: String { "Codex" }

    private let root: URL
    private let store: AIUsageStore
    private let queue: DispatchQueue

    private var emit: (([Sample]) -> Void)?
    private var rootWatcher: DispatchSourceFileSystemObject?
    private var dirWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// In-memory per-file cursor, seeded from persisted meta on first touch and advanced only after a
    /// successful `store.ingest`, so a failed commit leaves the next fs event to retry the same bytes.
    private struct Cursor {
        var offset: Int64
        var inode: UInt64
        var cumInput: Int64
        var cumOutput: Int64
        var cumCached: Int64
        var ordinal: Int64
        /// The latest model named by a `turn_context` line, attributed to the token_count snapshots that
        /// follow it. It is derived from the stream, not persisted: a from-zero re-read reconstructs it
        /// exactly (turn_context precedes its token_count events), and a mid-file restart resuming past a
        /// turn_context honestly books "unknown" until the next one arrives.
        var model: String
    }
    private var cursors: [String: Cursor] = [:]

    private static let metaKeyPrefix = "ai.codex."
    private static let offsetKeyPrefix = "ai.codex.offset:"
    private static let inodeKeyPrefix = "ai.codex.inode:"
    private static let cumInputKeyPrefix = "ai.codex.cumIn:"
    private static let cumOutputKeyPrefix = "ai.codex.cumOut:"
    private static let cumCachedKeyPrefix = "ai.codex.cumCache:"
    private static let ordinalKeyPrefix = "ai.codex.ord:"
    private static let allKeyPrefixes = [
        offsetKeyPrefix, inodeKeyPrefix, cumInputKeyPrefix,
        cumOutputKeyPrefix, cumCachedKeyPrefix, ordinalKeyPrefix,
    ]

    init(
        root: URL = CodexSource.defaultRoot,
        store: AIUsageStore,
        queue: DispatchQueue = DispatchQueue(label: "life.byte.ai.codex")
    ) {
        self.root = root
        self.store = store
        self.queue = queue
    }

    deinit {
        rootWatcher?.cancel()
        dirWatchers.values.forEach { $0.cancel() }
        fileWatchers.values.forEach { $0.cancel() }
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Meta keys (per file). Exposed for tests that simulate a restart.

    static func offsetKey(forPath path: String) -> String { offsetKeyPrefix + path }
    static func inodeKey(forPath path: String) -> String { inodeKeyPrefix + path }
    static func cumInputKey(forPath path: String) -> String { cumInputKeyPrefix + path }
    static func cumOutputKey(forPath path: String) -> String { cumOutputKeyPrefix + path }
    static func cumCachedKey(forPath path: String) -> String { cumCachedKeyPrefix + path }
    static func ordinalKey(forPath path: String) -> String { ordinalKeyPrefix + path }

    // MARK: - Lifecycle

    public func start(emit: @escaping ([Sample]) -> Void) {
        queue.sync {
            self.emit = emit
            self.pruneStaleMetaLocked()
            self.installRootWatcher()
            self.discoverLocked()
        }
    }

    public func stop() {
        queue.sync {
            self.rootWatcher?.cancel()
            self.rootWatcher = nil
            self.dirWatchers.values.forEach { $0.cancel() }
            self.dirWatchers.removeAll()
            self.fileWatchers.values.forEach { $0.cancel() }
            self.fileWatchers.removeAll()
            self.emit = nil
        }
    }

    /// Deletes persisted per-file meta rows whose file no longer exists, so a machine that has churned
    /// through thousands of sessions does not accumulate meta rows forever. Must run on `queue`.
    private func pruneStaleMetaLocked() {
        let fileManager = FileManager.default
        guard let keys = try? store.metaKeys(withPrefix: Self.metaKeyPrefix) else { return }
        for key in keys {
            guard let prefix = Self.allKeyPrefixes.first(where: key.hasPrefix) else { continue }
            let path = String(key.dropFirst(prefix.count))
            if !fileManager.fileExists(atPath: path) {
                try? store.deleteMeta(key: key)
            }
        }
    }

    // MARK: - Discovery

    /// Recursively walks the date tree from `root`, installing a directory watcher on every folder and a
    /// file watcher on every `rollout-*.jsonl` file, ingesting each newly discovered file from its cursor.
    /// Must run on `queue`.
    private func discoverLocked() {
        reconcileWatchersLocked()
        walkDirectoryLocked(root)
    }

    private func walkDirectoryLocked(_ directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                installDirWatcher(entry)
                walkDirectoryLocked(entry)
            } else if entry.lastPathComponent.hasPrefix("rollout-"), entry.pathExtension == "jsonl" {
                discoverFileLocked(path: entry.path)
            }
        }
    }

    /// Handles one discovered rollout file. A file modified within the recency window earns a persistent
    /// vnode watcher (installed once) that drives its tailing thereafter; an older file gets no watcher,
    /// so a machine holding thousands of historical rollouts never exhausts its file descriptors, and is
    /// instead re-tailed here whenever a cheap size check shows it grew past the consumed offset. Every
    /// file is still ingested at least once, since a first discovery has offset 0 and any non-empty file
    /// reads as grown. Must run on `queue`.
    private func discoverFileLocked(path: String) {
        // Already watched (a recent file discovered earlier): its own watcher drives tailing.
        guard fileWatchers[path] == nil else { return }
        if AISourceWatch.isRecent(path: path) {
            installFileWatcher(path)
            // Dedup makes the historical backfill safe.
            ingestLocked(path: path)
        } else {
            ingestIfGrewLocked(path: path)
        }
    }

    /// Re-tails an unwatched historical file only when its on-disk size has grown past the byte offset
    /// already consumed, so a file that never changes costs one `stat` per discovery pass and no ingest.
    /// A first discovery has offset 0, so any non-empty file is ingested exactly once. Must run on `queue`.
    private func ingestIfGrewLocked(path: String) {
        let offset = cursors[path]?.offset ?? metaInt(Self.offsetKey(forPath: path)) ?? 0
        guard let size = AISourceWatch.fileSize(path: path), size > offset else { return }
        ingestLocked(path: path)
    }

    /// Cancels and drops any file or directory watcher whose path has vanished, closing its descriptor.
    /// Must run on `queue`.
    private func reconcileWatchersLocked() {
        let fileManager = FileManager.default
        for path in Array(fileWatchers.keys) where !fileManager.fileExists(atPath: path) {
            fileWatchers[path]?.cancel()
            fileWatchers.removeValue(forKey: path)
        }
        for path in Array(dirWatchers.keys) where !fileManager.fileExists(atPath: path) {
            dirWatchers[path]?.cancel()
            dirWatchers.removeValue(forKey: path)
        }
    }

    /// Handles a file watcher's delete/rename event: cancel and drop the stale watcher, then, if the
    /// path still resolves to a file, treat it as an in-place replacement and re-tail. Must run on `queue`.
    private func handleFileVanishedLocked(path: String) {
        fileWatchers[path]?.cancel()
        fileWatchers.removeValue(forKey: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        installFileWatcher(path)
        ingestLocked(path: path)
    }

    // MARK: - Watchers

    private func installRootWatcher() {
        guard rootWatcher == nil else { return }
        rootWatcher = makeVnodeWatcher(path: root.path, mask: [.write, .rename, .delete]) { [weak self] _ in
            self?.discoverLocked()
        }
    }

    private func installDirWatcher(_ directory: URL) {
        guard dirWatchers[directory.path] == nil else { return }
        dirWatchers[directory.path] = makeVnodeWatcher(
            path: directory.path,
            mask: [.write, .rename, .delete]
        ) { [weak self] _ in
            self?.discoverLocked()
        }
    }

    private func installFileWatcher(_ path: String) {
        let watcher = makeVnodeWatcher(path: path, mask: [.write, .extend, .delete, .rename]) { [weak self] events in
            guard let self else { return }
            if events.contains(.delete) || events.contains(.rename) {
                self.handleFileVanishedLocked(path: path)
            } else {
                self.ingestLocked(path: path)
            }
        }
        guard let watcher else { return }
        fileWatchers[path] = watcher
    }

    private func makeVnodeWatcher(
        path: String,
        mask: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: queue
        )
        source.setEventHandler { [weak source] in
            guard let source else { return }
            handler(source.data)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    // MARK: - Ingest

    /// Test seam: sets `emit` and ingests one file synchronously without installing watchers.
    func ingest(path: String, emit: @escaping ([Sample]) -> Void) {
        queue.sync {
            self.emit = emit
            self.ingestLocked(path: path)
        }
    }

    /// Tails `path` from its cursor, turns each cumulative `token_count` snapshot into a clamped
    /// per-event delta, and hands the events plus the advanced cursor to the store's atomic `ingest`.
    ///
    /// Whenever the effective read starts at byte 0 (a fresh file, a restart with a cleared offset, or a
    /// rotation/truncation the tailer reports), the cumulative baselines and the ordinal reset to zero so
    /// the from-zero pass reproduces exactly the same deltas and dedup keys it produced originally, and
    /// the ledger collapses the re-read to nothing. The in-memory cursor advances only on a successful
    /// commit. Must run on `queue`.
    private func ingestLocked(path: String) {
        var cursor = cursors[path] ?? loadCursor(path: path)

        guard let result = try? FileTailer.read(
            path: path, offset: cursor.offset, priorInode: cursor.inode
        ) else { return }

        // A from-zero read (offset was 0, or the tailer reset on rotation/truncation) recomputes every
        // delta from a zero baseline, so the ordinal and cumulative baselines must restart too.
        if cursor.offset == 0 || result.didReset {
            cursor.cumInput = 0
            cursor.cumOutput = 0
            cursor.cumCached = 0
            cursor.ordinal = 0
            cursor.model = "unknown"
        }

        let sessionId = URL(fileURLWithPath: path).lastPathComponent
        var events: [AIIngestEvent] = []
        for line in result.lines {
            // A turn_context line names the model for the snapshots that follow it; track it and move on.
            if let model = CodexParser.turnContextModel(line: line) {
                cursor.model = model
                continue
            }
            guard let snapshot = CodexParser.parse(line: line) else { continue }
            let deltaInput = max(0, snapshot.totalInput - cursor.cumInput)
            let deltaOutput = max(0, snapshot.totalOutput - cursor.cumOutput)
            let deltaCached = max(0, snapshot.totalCached - cursor.cumCached)
            cursor.cumInput = snapshot.totalInput
            cursor.cumOutput = snapshot.totalOutput
            cursor.cumCached = snapshot.totalCached

            let key = "codex:\(sessionId)|\(cursor.ordinal)"
            cursor.ordinal += 1
            events.append(AIIngestEvent(
                dedupKey: key,
                samples: samples(input: deltaInput, output: deltaOutput, cached: deltaCached, at: snapshot.timestamp),
                attribution: AIUsageAttribution(
                    source: "codex", model: cursor.model,
                    sessionId: sessionId, timestamp: snapshot.timestamp
                )
            ))
        }

        cursor.offset = result.newOffset
        cursor.inode = result.inode
        let meta: [(String, Int64)] = [
            (Self.offsetKey(forPath: path), cursor.offset),
            (Self.inodeKey(forPath: path), Int64(bitPattern: cursor.inode)),
            (Self.cumInputKey(forPath: path), cursor.cumInput),
            (Self.cumOutputKey(forPath: path), cursor.cumOutput),
            (Self.cumCachedKey(forPath: path), cursor.cumCached),
            (Self.ordinalKey(forPath: path), cursor.ordinal),
        ]

        let recorded: [Sample]
        do {
            recorded = try store.ingest(events: events, meta: meta)
        } catch {
            return
        }
        cursors[path] = cursor
        if !recorded.isEmpty { emit?(recorded) }
    }

    private func samples(input: Int64, output: Int64, cached: Int64, at timestamp: Date) -> [Sample] {
        var out: [Sample] = []
        if input != 0 { out.append(Sample(kind: .aiInputTokens, value: input, timestamp: timestamp)) }
        if output != 0 { out.append(Sample(kind: .aiOutputTokens, value: output, timestamp: timestamp)) }
        if cached != 0 { out.append(Sample(kind: .aiCacheReadTokens, value: cached, timestamp: timestamp)) }
        return out
    }

    private func loadCursor(path: String) -> Cursor {
        Cursor(
            offset: metaInt(Self.offsetKey(forPath: path)) ?? 0,
            inode: UInt64(bitPattern: metaInt(Self.inodeKey(forPath: path)) ?? 0),
            cumInput: metaInt(Self.cumInputKey(forPath: path)) ?? 0,
            cumOutput: metaInt(Self.cumOutputKey(forPath: path)) ?? 0,
            cumCached: metaInt(Self.cumCachedKey(forPath: path)) ?? 0,
            ordinal: metaInt(Self.ordinalKey(forPath: path)) ?? 0,
            model: "unknown"
        )
    }

    private func metaInt(_ key: String) -> Int64? {
        (try? store.metaInt(key)).flatMap { $0 }
    }
}

// MARK: - Test seams

extension CodexSource {
    /// Re-runs discovery synchronously (reconciling stale watchers and installing new ones).
    func rediscover() { queue.sync { self.discoverLocked() } }

    /// Simulates a file watcher's delete/rename event for `path`.
    func simulateVanish(path: String) { queue.sync { self.handleFileVanishedLocked(path: path) } }

    /// The paths of the file watchers currently installed.
    var watchedFilePaths: [String] { queue.sync { Array(self.fileWatchers.keys) } }

    /// The paths of the directory watchers currently installed.
    var watchedDirPaths: [String] { queue.sync { Array(self.dirWatchers.keys) } }
}
