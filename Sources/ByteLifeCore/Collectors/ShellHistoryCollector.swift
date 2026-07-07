import Foundation

/// Pure, chunk-resumable counter for shell-history entries. It carries only enough state between reads to
/// count appended ENTRIES, never command text: whether the file is in zsh extended-history format (once a
/// `: <epoch>:<duration>;` header is seen it stays extended) and whether the previous physical line ended
/// with a backslash continuation. Extended entries are counted by their headers alone, so a command that
/// spans continuation lines still counts once; a plain history counts each non-empty line.
struct ShellHistoryCounter: Equatable {
    /// True once any extended-history header has been seen, so later header-less lines read as continuation
    /// noise rather than plain-history commands. Persisted per file so a restart resumes the right mode.
    var extended = false
    /// True when the previous consumed line ended with an unescaped backslash, so the next line continues
    /// its command and must not count. In-memory only: a continuation straddling a restart is a rare, at
    /// most one-off miscount that the burst caveat already tolerates.
    var continuing = false

    /// Folds a batch of newly appended complete lines, returning the number of entries they add and
    /// advancing the carried state. In extended mode only headers count and continuation lines are skipped;
    /// in plain mode every non-empty line is one command.
    mutating func count(lines: [String]) -> Int {
        var added = 0
        for line in lines {
            if extended {
                // A continuation of the previous command's line is never its own entry.
                if continuing {
                    continuing = Self.endsWithContinuation(line)
                    continue
                }
                if Self.isExtendedHeader(line) { added += 1 }
                // A header-less, non-continuation line is continuation noise; it never counts.
                continuing = Self.endsWithContinuation(line)
            } else if Self.isExtendedHeader(line) {
                // First header seen: switch to extended mode for this and every later read.
                extended = true
                added += 1
                continuing = Self.endsWithContinuation(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Plain history: each non-empty line is one command; backslashes do not join lines here.
                added += 1
            }
        }
        return added
    }

    /// True when `line` is a zsh extended-history header of the form `: <epoch>:<duration>;` (both fields
    /// all digits). The command text follows the semicolon and is never inspected.
    static func isExtendedHeader(_ line: String) -> Bool {
        guard line.hasPrefix(": ") else { return false }
        let rest = line.dropFirst(2)
        guard let semicolon = rest.firstIndex(of: ";") else { return false }
        let head = rest[rest.startIndex..<semicolon]
        let parts = head.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
    }

    /// True when `line` ends with an odd number of backslashes, the mark of a continued command line.
    static func endsWithContinuation(_ line: String) -> Bool {
        var backslashes = 0
        for character in line.reversed() {
            if character == "\\" { backslashes += 1 } else { break }
        }
        return backslashes % 2 == 1
    }
}

/// Counts commands appended to the shell history files into `commandsRun`, storing counts only, never text.
///
/// It tails `~/.zsh_history` and `~/.bash_history` (injectable for tests) with the same offset/inode
/// discipline the AI sources use: `FileTailer` returns only complete lines since the persisted byte offset,
/// a changed inode or a shrunk file restarts the read from byte 0, and the offset, inode, and extended-mode
/// flag persist per file so a restart resumes exactly where it left off. A file first seen with no
/// persisted offset is baselined to its current end, so an existing multi-thousand-line history is never
/// replayed as a burst of "commands run"; only genuinely appended entries count thereafter.
///
/// Watching follows the bounded-recency discipline from `AISourceWatch`: a recently modified history earns a
/// persistent vnode watcher that drives its tailing, while an older one gets none and is re-checked with a
/// cheap size `stat` on each periodic discovery pass. Availability is `running` while at least one history
/// file exists and degrades to `sourceMissing` honestly when neither does. All state lives behind one
/// serial `queue`; tests inject the roots and clock and call the ingest seam directly.
public final class ShellHistoryCollector: Collector, @unchecked Sendable {
    public let id = "shell"
    public let family: MetricFamily = .auxiliary
    public var onAvailabilityChange: ((Availability) -> Void)?

    private let store: CounterStore
    private let roots: [String]
    private let now: () -> Date
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "life.byte.shell")

    private let lock = NSLock()
    private var backingAvailability: Availability = .running
    private var scheduler: Scheduler?
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]

    private struct Cursor {
        var offset: Int64
        var inode: UInt64
        var counter: ShellHistoryCounter
    }
    // Confined to `queue`.
    private var cursors: [String: Cursor] = [:]

    private static let offsetKeyPrefix = "shell.offset:"
    private static let inodeKeyPrefix = "shell.inode:"
    private static let extendedKeyPrefix = "shell.extended:"

    /// Production entry point: tails the real history files every `interval` with the live clock.
    public convenience init(
        store: SampleStore,
        roots: [String] = ShellHistoryCollector.defaultRoots,
        interval: DispatchTimeInterval = .seconds(60),
        now: @escaping () -> Date = Date.init
    ) {
        self.init(store: store as CounterStore, roots: roots, interval: interval, now: now)
    }

    /// Test seam: injects any `CounterStore` and an explicit set of roots and clock.
    init(
        store: CounterStore,
        roots: [String] = ShellHistoryCollector.defaultRoots,
        interval: DispatchTimeInterval = .seconds(60),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.roots = roots
        self.interval = interval
        self.now = now
    }

    deinit { stop() }

    public static var defaultRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.zsh_history", home + "/.bash_history"]
    }

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return backingAvailability
    }

    static func offsetKey(forPath path: String) -> String { offsetKeyPrefix + path }
    static func inodeKey(forPath path: String) -> String { inodeKeyPrefix + path }
    static func extendedKey(forPath path: String) -> String { extendedKeyPrefix + path }

    // MARK: - Lifecycle

    public func start() {
        lock.lock()
        let alreadyRunning = scheduler != nil
        lock.unlock()
        guard !alreadyRunning else { return }
        queue.sync { self.discoverLocked() }
        let scheduler = Scheduler(queue: queue, interval: interval) { [weak self] in self?.discoverLocked() }
        lock.lock(); self.scheduler = scheduler; lock.unlock()
        scheduler.start()
    }

    public func stop() {
        lock.lock()
        scheduler?.stop()
        scheduler = nil
        let watchers = fileWatchers
        fileWatchers.removeAll()
        lock.unlock()
        watchers.values.forEach { $0.cancel() }
    }

    // MARK: - Discovery

    /// One discovery pass: reconcile stale watchers, then for each existing history file either let its
    /// installed watcher drive tailing, install one and ingest when the file is recent, or re-tail on a
    /// cheap size check when it is old. Updates availability from whether any history file exists at all.
    /// Must run on `queue`.
    private func discoverLocked() {
        reconcileWatchersLocked()
        let fileManager = FileManager.default
        var anyExists = false
        for path in roots {
            guard fileManager.fileExists(atPath: path) else { continue }
            anyExists = true
            if fileWatchers[path] != nil { continue }
            if AISourceWatch.isRecent(path: path) {
                installFileWatcher(path)
                ingestLocked(path: path)
            } else {
                ingestIfGrewLocked(path: path)
            }
        }
        setAvailability(anyExists ? .running : .sourceMissing)
    }

    /// Re-tails an unwatched history only when its on-disk size has grown past the consumed offset, so an
    /// idle history costs one `stat` per pass and no ingest. Must run on `queue`.
    private func ingestIfGrewLocked(path: String) {
        let offset = cursors[path]?.offset ?? metaInt(Self.offsetKey(forPath: path))
        // No cursor yet: the first sight baselines to the file's end, so ingest once to record it.
        guard let offset else { ingestLocked(path: path); return }
        guard let size = AISourceWatch.fileSize(path: path), size > offset else { return }
        ingestLocked(path: path)
    }

    private func reconcileWatchersLocked() {
        let fileManager = FileManager.default
        for path in Array(fileWatchers.keys) where !fileManager.fileExists(atPath: path) {
            fileWatchers[path]?.cancel()
            fileWatchers.removeValue(forKey: path)
        }
    }

    /// Handles a watcher's delete/rename event: drop the stale watcher, and if the path still resolves,
    /// treat it as an in-place replacement and re-tail (the tailer's inode check restarts from 0). Then
    /// refresh availability. Must run on `queue`.
    private func handleFileVanishedLocked(path: String) {
        fileWatchers[path]?.cancel()
        fileWatchers.removeValue(forKey: path)
        if FileManager.default.fileExists(atPath: path) {
            installFileWatcher(path)
            ingestLocked(path: path)
        }
        setAvailability(roots.contains { FileManager.default.fileExists(atPath: $0) } ? .running : .sourceMissing)
    }

    // MARK: - Watchers

    private func installFileWatcher(_ path: String) {
        guard fileWatchers[path] == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.handleFileVanishedLocked(path: path)
            } else {
                self.ingestLocked(path: path)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatchers[path] = source
    }

    // MARK: - Ingest

    /// Test seam: ingests one file synchronously without installing a watcher or scheduler.
    func ingest(path: String) {
        queue.sync { self.ingestLocked(path: path) }
    }

    /// Tails `path` from its cursor, counts the appended entries, and commits the `commandsRun` delta with
    /// the advanced offset, inode, and extended flag in one transaction. A from-zero read (a fresh offset
    /// or a rotation/truncation the tailer reports) resets the counter so format detection restarts. The
    /// in-memory cursor advances only on a clean commit. Must run on `queue`.
    private func ingestLocked(path: String) {
        var cursor = cursors[path] ?? loadCursor(path: path)

        guard let result = try? FileTailer.read(
            path: path, offset: cursor.offset, priorInode: cursor.inode
        ) else { return }

        if cursor.offset == 0 || result.didReset {
            cursor.counter = ShellHistoryCounter()
        }

        let added = cursor.counter.count(lines: result.lines)
        cursor.offset = result.newOffset
        cursor.inode = result.inode

        var samples: [Sample] = []
        if added > 0 { samples.append(Sample(kind: .commandsRun, value: Int64(added), timestamp: now())) }
        let meta: [String: Int64] = [
            Self.offsetKey(forPath: path): cursor.offset,
            Self.inodeKey(forPath: path): Int64(bitPattern: cursor.inode),
            Self.extendedKey(forPath: path): cursor.counter.extended ? 1 : 0,
        ]

        do {
            try store.record(samples, settingMeta: meta)
        } catch {
            return
        }
        cursors[path] = cursor
    }

    /// Loads a file's cursor: from persisted meta when present, otherwise a first-sight baseline set to the
    /// file's current end so pre-existing history is never counted as appended. Must run on `queue`.
    private func loadCursor(path: String) -> Cursor {
        if let offset = metaInt(Self.offsetKey(forPath: path)) {
            return Cursor(
                offset: offset,
                inode: UInt64(bitPattern: metaInt(Self.inodeKey(forPath: path)) ?? 0),
                counter: ShellHistoryCounter(extended: (metaInt(Self.extendedKey(forPath: path)) ?? 0) != 0)
            )
        }
        var status = stat()
        let ok = stat(path, &status) == 0
        return Cursor(
            offset: ok ? Int64(status.st_size) : 0,
            inode: ok ? UInt64(status.st_ino) : 0,
            counter: ShellHistoryCounter()
        )
    }

    private func metaInt(_ key: String) -> Int64? {
        (try? store.metaInt(key)).flatMap { $0 }
    }

    private func setAvailability(_ value: Availability) {
        lock.lock()
        let changed = value != backingAvailability
        backingAvailability = value
        lock.unlock()
        if changed { onAvailabilityChange?(value) }
    }
}

// MARK: - Test seams

extension ShellHistoryCollector {
    /// Re-runs discovery synchronously.
    func rediscover() { queue.sync { self.discoverLocked() } }

    /// The paths of the file watchers currently installed.
    var watchedFilePaths: [String] { queue.sync { Array(self.fileWatchers.keys) } }
}
