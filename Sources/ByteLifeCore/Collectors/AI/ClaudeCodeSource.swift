import Foundation

/// The subset of `SampleStore` the AI sources depend on. Extracted as a protocol so tests can inject
/// a failing store and prove that a failed commit advances neither the offset nor the samples.
protocol AIUsageStore: AnyObject {
    func ingest(events: [AIIngestEvent], meta: [(String, Int64)]) throws -> [Sample]
    func metaInt(_ key: String) throws -> Int64?
    func metaKeys(withPrefix prefix: String) throws -> [String]
    func deleteMeta(key: String) throws
}

extension SampleStore: AIUsageStore {}

/// Watches `~/.claude/projects` (injectable for tests) for Claude Code JSONL transcripts, tails new
/// lines, deduplicates usage against the store's persisted `ai_seen` ledger, and records the resulting
/// additive samples through the store's atomic `ingest`.
///
/// All mutable state lives behind one serial `queue`. The directory-level vnode watchers rediscover
/// project folders and session files as they appear. Only a file modified within
/// `AISourceWatch.recencyWindow` earns a persistent per-file vnode watcher (which drives its tailing and
/// tears itself down when the file is deleted or renamed); an older file gets none and is re-tailed on
/// each discovery pass only when a cheap `stat` shows it grew, so a machine with hundreds of historical
/// transcripts stays well under its file-descriptor limit. Per-file byte offset and inode persist in
/// store meta, so restarts resume exactly where they left off, and every watcher file descriptor
/// closes in its cancel handler.
public final class ClaudeCodeSource: AIUsageSource, @unchecked Sendable {
    public let id = "ai.claudeCode"
    public var displayName: String { "Claude Code" }

    private let root: URL
    private let store: AIUsageStore
    private let queue: DispatchQueue

    private var emit: (([Sample]) -> Void)?
    private var rootWatcher: DispatchSourceFileSystemObject?
    private var projectWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]

    // In-memory tail cursor per file, seeded from persisted meta on first touch and advanced only
    // after a successful `store.ingest`, so a failed commit leaves the next fs event to retry.
    private var offsets: [String: Int64] = [:]
    private var inodes: [String: UInt64] = [:]

    private static let metaKeyPrefix = "ai.claudeCode."
    private static let offsetKeyPrefix = "ai.claudeCode.offset:"
    private static let inodeKeyPrefix = "ai.claudeCode.inode:"

    init(
        root: URL = ClaudeCodeSource.defaultRoot,
        store: AIUsageStore,
        queue: DispatchQueue = DispatchQueue(label: "life.byte.ai.claudeCode")
    ) {
        self.root = root
        self.store = store
        self.queue = queue
    }

    deinit {
        // Cancel synchronously without hopping the queue; deinit already implies no concurrent use.
        rootWatcher?.cancel()
        projectWatchers.values.forEach { $0.cancel() }
        fileWatchers.values.forEach { $0.cancel() }
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

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
            self.projectWatchers.values.forEach { $0.cancel() }
            self.projectWatchers.removeAll()
            self.fileWatchers.values.forEach { $0.cancel() }
            self.fileWatchers.removeAll()
            self.emit = nil
        }
    }

    // MARK: - Meta keys (per file). Exposed for tests that simulate a restart.

    static func offsetKey(forPath path: String) -> String { offsetKeyPrefix + path }
    static func inodeKey(forPath path: String) -> String { inodeKeyPrefix + path }

    /// Deletes persisted offset/inode meta rows whose file no longer exists, so a machine that has
    /// churned through thousands of sessions does not accumulate meta rows forever. Must run on `queue`.
    private func pruneStaleMetaLocked() {
        let fileManager = FileManager.default
        guard let keys = try? store.metaKeys(withPrefix: Self.metaKeyPrefix) else { return }
        for key in keys {
            let path: String
            if key.hasPrefix(Self.offsetKeyPrefix) {
                path = String(key.dropFirst(Self.offsetKeyPrefix.count))
            } else if key.hasPrefix(Self.inodeKeyPrefix) {
                path = String(key.dropFirst(Self.inodeKeyPrefix.count))
            } else {
                continue
            }
            if !fileManager.fileExists(atPath: path) {
                try? store.deleteMeta(key: key)
            }
        }
    }

    // MARK: - Discovery

    private func discoverLocked() {
        reconcileWatchersLocked()

        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for directory in projectDirs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            installProjectWatcher(directory)

            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                discoverFileLocked(path: file.path)
            }
        }
    }

    /// Handles one discovered transcript file. A file modified within the recency window earns a
    /// persistent vnode watcher (installed once) that drives its tailing thereafter; an older file gets
    /// no watcher, so a machine holding hundreds of historical transcripts never exhausts its file
    /// descriptors, and is instead re-tailed here whenever a cheap size check shows it grew past the
    /// consumed offset. Every file is still ingested at least once, since a first discovery has offset 0
    /// and any non-empty file reads as grown. Must run on `queue`.
    private func discoverFileLocked(path: String) {
        // Already watched (a recent file discovered earlier): its own watcher drives tailing.
        guard fileWatchers[path] == nil else { return }
        if AISourceWatch.isRecent(path: path) {
            installFileWatcher(path)
            // Dedup makes the historical backfill safe and intentional.
            ingestLocked(path: path)
        } else {
            ingestIfGrewLocked(path: path)
        }
    }

    /// Re-tails an unwatched historical file only when its on-disk size has grown past the byte offset
    /// already consumed, so a file that never changes costs one `stat` per discovery pass and no ingest.
    /// A first discovery has offset 0, so any non-empty file is ingested exactly once. Must run on `queue`.
    private func ingestIfGrewLocked(path: String) {
        let offset = offsets[path] ?? metaInt(Self.offsetKey(forPath: path)) ?? 0
        guard let size = AISourceWatch.fileSize(path: path), size > offset else { return }
        ingestLocked(path: path)
    }

    /// Cancels and drops any file or project watcher whose path has vanished, closing its descriptor.
    /// Without this, watchers (and their file descriptors) would only ever accumulate. Must run on `queue`.
    private func reconcileWatchersLocked() {
        let fileManager = FileManager.default
        for path in Array(fileWatchers.keys) where !fileManager.fileExists(atPath: path) {
            fileWatchers[path]?.cancel()
            fileWatchers.removeValue(forKey: path)
        }
        for path in Array(projectWatchers.keys) where !fileManager.fileExists(atPath: path) {
            projectWatchers[path]?.cancel()
            projectWatchers.removeValue(forKey: path)
        }
    }

    /// Handles a file watcher's delete/rename event: cancel and drop the stale watcher (its cancel
    /// handler closes the descriptor), then, if the path still resolves to a file, treat it as an
    /// in-place replacement — re-watch and re-tail. FileTailer's inode reset plus dedup make the
    /// re-ingest safe. Must run on `queue`.
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

    private func installProjectWatcher(_ directory: URL) {
        guard projectWatchers[directory.path] == nil else { return }
        projectWatchers[directory.path] = makeVnodeWatcher(
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

    /// Tails `path` from its in-memory cursor, parses, and hands the events plus the advanced
    /// offset/inode to the store's atomic `ingest`. The store dedups and, in one transaction, records
    /// the newly seen samples and persists the offset/inode together. The in-memory cursor advances
    /// only on success; on a throw it is left unchanged so the next fs event retries the same bytes,
    /// which dedup keeps from double-counting. Must run on `queue`.
    private func ingestLocked(path: String) {
        let offsetKey = Self.offsetKey(forPath: path)
        let inodeKey = Self.inodeKey(forPath: path)
        let offset = offsets[path] ?? metaInt(offsetKey) ?? 0
        let priorInode = inodes[path] ?? UInt64(bitPattern: metaInt(inodeKey) ?? 0)

        guard let result = try? FileTailer.read(path: path, offset: offset, priorInode: priorInode) else {
            return
        }

        var events: [AIIngestEvent] = []
        for line in result.lines {
            guard let event = ClaudeCodeParser.parse(line: line) else { continue }
            let attribution = AIUsageAttribution(
                source: "claudeCode", model: event.model,
                sessionId: event.sessionId, timestamp: event.timestamp
            )
            events.append(AIIngestEvent(
                dedupKey: event.dedupKey, samples: event.samples(), attribution: attribution
            ))
        }

        let meta: [(String, Int64)] = [
            (offsetKey, result.newOffset),
            (inodeKey, Int64(bitPattern: result.inode)),
        ]
        let recorded: [Sample]
        do {
            recorded = try store.ingest(events: events, meta: meta)
        } catch {
            return
        }
        offsets[path] = result.newOffset
        inodes[path] = result.inode
        if !recorded.isEmpty { emit?(recorded) }
    }

    private func metaInt(_ key: String) -> Int64? {
        (try? store.metaInt(key)).flatMap { $0 }
    }
}

// MARK: - Test seams

extension ClaudeCodeSource {
    /// Re-runs discovery synchronously (reconciling stale watchers and installing new ones).
    func rediscover() { queue.sync { self.discoverLocked() } }

    /// Simulates a file watcher's delete/rename event for `path`.
    func simulateVanish(path: String) { queue.sync { self.handleFileVanishedLocked(path: path) } }

    /// The paths of the file watchers currently installed.
    var watchedFilePaths: [String] { queue.sync { Array(self.fileWatchers.keys) } }

    /// The paths of the project watchers currently installed.
    var watchedProjectPaths: [String] { queue.sync { Array(self.projectWatchers.keys) } }
}
