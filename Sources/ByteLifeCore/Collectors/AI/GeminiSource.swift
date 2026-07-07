import Foundation

/// Watches `~/.gemini/tmp` (injectable for tests) for Gemini CLI chat session files
/// (`<hash>/chats/session-*.json`), parses the per-turn token counts each assistant message carries,
/// deduplicates against the store's `ai_seen` ledger, and records the resulting additive samples
/// through the store's atomic `ingest`.
///
/// Gemini rewrites a session file wholesale on each update rather than appending, so byte-offset tailing
/// does not apply. Instead the source re-reads the whole file from zero on every change. To keep the
/// re-read from double-counting it persists a per-file high-water mark (the count of messages already
/// ingested) and drops that many leading messages before ingest, so an appended file never re-books its
/// early turns even after their `ai_seen` dedup keys have aged out of the ledger; `ai_seen` remains the
/// safety net for any overlap after a rewrite or truncation. To avoid re-parsing unchanged files it also
/// persists each file's modification time and skips a file whose mtime has not advanced.
///
/// All mutable state lives behind one serial `queue`. Directory watchers cover every level so new hash
/// and chats folders and session files are rediscovered. Only a file modified within
/// `AISourceWatch.recencyWindow` earns a persistent per-file vnode watcher (which drives its re-reads and
/// tears itself down when the file is deleted or renamed); an older file gets none and is re-checked by
/// the cheap mtime guard on each discovery pass, so a machine with many historical sessions stays well
/// under its file-descriptor limit.
public final class GeminiSource: AIUsageSource, @unchecked Sendable {
    public let id = "ai.gemini"
    public var displayName: String { "Gemini" }

    private let root: URL
    private let store: AIUsageStore
    private let queue: DispatchQueue

    private var emit: (([Sample]) -> Void)?
    private var rootWatcher: DispatchSourceFileSystemObject?
    private var dirWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// In-memory per-file modification time, seeded from persisted meta and advanced only after a
    /// successful `store.ingest`.
    private var modTimes: [String: Int64] = [:]
    /// In-memory per-file high-water mark: the count of usage-bearing messages already ingested from the
    /// file, seeded from persisted meta and advanced only after a successful `store.ingest`. A re-read
    /// skips this many leading messages so an appended file never re-counts its early turns, even after
    /// their `ai_seen` dedup keys have aged out of the ledger.
    private var counts: [String: Int] = [:]

    private static let metaKeyPrefix = "ai.gemini."
    private static let mtimeKeyPrefix = "ai.gemini.mtime:"
    private static let countKeyPrefix = "ai.gemini.count:"
    private static let allKeyPrefixes = [mtimeKeyPrefix, countKeyPrefix]

    init(
        root: URL = GeminiSource.defaultRoot,
        store: AIUsageStore,
        queue: DispatchQueue = DispatchQueue(label: "life.byte.ai.gemini")
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
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    public var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func mtimeKey(forPath path: String) -> String { mtimeKeyPrefix + path }
    static func countKey(forPath path: String) -> String { countKeyPrefix + path }

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

    private func discoverLocked() {
        reconcileWatchersLocked()
        walkDirectoryLocked(root)
    }

    /// Recursively walks the tmp tree, installing a directory watcher on every folder and a file watcher
    /// on every `session-*.json` chat file, re-ingesting each. The per-project `logs.json` (no token
    /// counts) and the `bin` helper directory are simply not matched. Must run on `queue`.
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
            } else if entry.lastPathComponent.hasPrefix("session-"), entry.pathExtension == "json" {
                discoverFileLocked(path: entry.path)
            }
        }
    }

    /// Handles one discovered chat session file. A file modified within the recency window earns a
    /// persistent vnode watcher (installed once) that drives its re-reads thereafter; an older file gets
    /// no watcher, so a machine holding many historical sessions never exhausts its file descriptors.
    /// Either way `ingestLocked` runs and its mtime guard makes the re-check cheap: an unchanged file is
    /// stat'd and skipped, and only a rewritten one is re-parsed. Must run on `queue`.
    private func discoverFileLocked(path: String) {
        if fileWatchers[path] == nil, AISourceWatch.isRecent(path: path) {
            installFileWatcher(path)
        }
        ingestLocked(path: path)
    }

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

    /// Re-reads the whole session file from zero, parses its per-turn token messages, and hands the newly
    /// appended ones plus the file's new modification time and message high-water mark to the store's
    /// atomic `ingest`. A file whose mtime has not advanced since the last recorded ingest is skipped, so
    /// unchanged historical sessions are never re-parsed on relaunch.
    ///
    /// Because Gemini rewrites the file wholesale, a re-read always re-parses every message. The stored
    /// high-water mark (the count already ingested) is the primary guard against double-counting: the
    /// leading `mark` messages are dropped before ingest, so an append never re-counts its early turns
    /// even after their `ai_seen` dedup keys have aged out of the ledger. When the file now holds FEWER
    /// messages than the mark (a rewrite or truncation), the mark is meaningless, so it drops to zero for
    /// this pass and every message is offered to `ingest`, whose `ai_seen` dedup collapses any overlap.
    /// The in-memory mtime and mark advance only on a successful commit. Must run on `queue`.
    private func ingestLocked(path: String) {
        guard let modTime = modificationTime(path: path) else { return }
        let lastModTime = modTimes[path] ?? metaInt(Self.mtimeKey(forPath: path)) ?? 0
        if modTime == lastModTime, lastModTime != 0 { return }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let allEvents = GeminiParser.parse(data: data).map {
            AIIngestEvent(
                dedupKey: $0.dedupKey, samples: $0.samples(),
                attribution: AIUsageAttribution(
                    source: "gemini", model: $0.model,
                    sessionId: $0.sessionId, timestamp: $0.timestamp
                )
            )
        }

        let storedMark = counts[path] ?? Int(metaInt(Self.countKey(forPath: path)) ?? 0)
        // A file shorter than the mark was rewritten or truncated: skip nothing and let ai_seen dedup.
        let skip = allEvents.count < storedMark ? 0 : storedMark
        let newEvents = Array(allEvents.dropFirst(skip))
        let newMark = Int64(allEvents.count)
        let meta = [(Self.mtimeKey(forPath: path), modTime), (Self.countKey(forPath: path), newMark)]

        let recorded: [Sample]
        do {
            recorded = try store.ingest(events: newEvents, meta: meta)
        } catch {
            return
        }
        modTimes[path] = modTime
        counts[path] = allEvents.count
        if !recorded.isEmpty { emit?(recorded) }
    }

    /// The file's modification time as nanoseconds since the epoch, or nil when it cannot be stat'd.
    private func modificationTime(path: String) -> Int64? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
    }

    private func metaInt(_ key: String) -> Int64? {
        (try? store.metaInt(key)).flatMap { $0 }
    }
}

// MARK: - Test seams

extension GeminiSource {
    /// Re-runs discovery synchronously (reconciling stale watchers and installing new ones).
    func rediscover() { queue.sync { self.discoverLocked() } }

    /// Simulates a file watcher's delete/rename event for `path`.
    func simulateVanish(path: String) { queue.sync { self.handleFileVanishedLocked(path: path) } }

    /// The paths of the file watchers currently installed.
    var watchedFilePaths: [String] { queue.sync { Array(self.fileWatchers.keys) } }

    /// The paths of the directory watchers currently installed.
    var watchedDirPaths: [String] { queue.sync { Array(self.dirWatchers.keys) } }
}
