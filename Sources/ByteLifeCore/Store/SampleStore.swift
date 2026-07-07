import Foundation
import SQLite3

/// Tells SQLite to copy a bound value immediately, because the Swift string backing it is a
/// temporary the C call outlives. SQLITE_STATIC would let SQLite read freed memory here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One AI usage record to ingest atomically: a dedup key and the additive samples it contributes.
/// The store records the samples only when the key is newly seen, so the whole `ingest` batch stays
/// exactly-once even if it is retried after a failure.
public struct AIIngestEvent: Equatable, Sendable {
    public let dedupKey: String
    public let samples: [Sample]

    public init(dedupKey: String, samples: [Sample]) {
        self.dedupKey = dedupKey
        self.samples = samples
    }
}

/// A closed day bound to its immutable receipt. Stored once by `insertReconciliation` and read back
/// verbatim thereafter; the receipt text is never recomposed.
public struct Reconciliation: Equatable, Sendable {
    public let dayEpoch: Int64
    /// Wall-clock Unix seconds the books were closed.
    public let closedAt: Int64
    public let receiptText: String
    /// SHA-256 over the receipt body, truncated to 16 hex characters.
    public let contentHash: String
    /// "BALANCED" or "FLAGGED".
    public let stamp: String
    /// The day's single margin comment.
    public let comment: String

    public init(dayEpoch: Int64, closedAt: Int64, receiptText: String,
                contentHash: String, stamp: String, comment: String) {
        self.dayEpoch = dayEpoch
        self.closedAt = closedAt
        self.receiptText = receiptText
        self.contentHash = contentHash
        self.stamp = stamp
        self.comment = comment
    }
}

/// Durable per-minute accumulator for every metric sample, plus the `meta` key/value store and
/// the `ai_seen` dedup ledger.
///
/// A `final class` guarded by one private serial queue rather than an actor: every public method
/// runs synchronously on that queue, so C callbacks and timer handlers can call the store directly
/// without hopping onto an async context. All public methods are therefore safe to call from any
/// thread.
public final class SampleStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "life.byte.SampleStore")

    /// AI dedup entries older than this are dropped on open. Wide enough to survive re-tailing a
    /// truncated transcript, small enough to keep the ledger bounded.
    private static let defaultDedupRetentionDays = 45

    /// Opens (creating if needed) the database at `path`, configures pragmas, runs migrations, and
    /// prunes the dedup ledger by age.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let error = SQLiteError.from(db: handle, code: rc)
            if let handle { sqlite3_close_v2(handle) }
            throw error
        }
        db = handle
        do {
            try configure()
            try Migrations.migrate(handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        pruneAISeen(olderThanDays: Self.defaultDedupRetentionDays)
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Writes

    /// Accumulates a batch of samples in one transaction. Each sample is bucketed at its own
    /// timestamp and UPSERT-added into the matching minute cell.
    public func record(_ samples: [Sample]) throws {
        try record(samples, settingMeta: [:])
    }

    /// Accumulates a batch of samples AND upserts a set of meta int64 baselines in ONE transaction,
    /// so a counter collector's persisted baseline never advances past deltas it failed to record.
    /// Either the samples and every baseline commit together or nothing does; the caller then advances
    /// its in-memory baselines only on a clean return.
    public func record(_ samples: [Sample], settingMeta meta: [String: Int64]) throws {
        guard !samples.isEmpty || !meta.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                try insertSamplesLocked(samples)
                try upsertMetaIntsLocked(meta)
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// UPSERT-adds each sample into its minute cell. Assumes a transaction is already open on `queue`.
    private func insertSamplesLocked(_ samples: [Sample]) throws {
        guard !samples.isEmpty else { return }
        let stmt = try prepare("""
            INSERT INTO samples (day_epoch, minute, kind, value)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (day_epoch, minute, kind)
            DO UPDATE SET value = value + excluded.value;
            """)
        defer { sqlite3_finalize(stmt) }
        for sample in samples {
            let bucket = DayBucket(date: sample.timestamp)
            sqlite3_bind_int64(stmt, 1, bucket.dayEpoch)
            sqlite3_bind_int(stmt, 2, bucket.minute)
            bindText(stmt, 3, sample.kind.rawValue)
            sqlite3_bind_int64(stmt, 4, sample.value)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }

    /// UPSERTs each meta int64. Assumes a transaction is already open on `queue`.
    private func upsertMetaIntsLocked(_ meta: [String: Int64]) throws {
        guard !meta.isEmpty else { return }
        let stmt = try prepare("""
            INSERT INTO meta (key, ival) VALUES (?, ?)
            ON CONFLICT (key) DO UPDATE SET ival = excluded.ival;
            """)
        defer { sqlite3_finalize(stmt) }
        for (key, value) in meta {
            bindText(stmt, 1, key)
            sqlite3_bind_int64(stmt, 2, value)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
    }

    /// Atomically ingests a batch of AI usage. In one `BEGIN IMMEDIATE ... COMMIT`: for each event,
    /// `INSERT OR IGNORE` its dedup key (recording today as its first-seen day, so pruning is by
    /// time-since-seen), and only when the key is newly inserted accumulate its samples into the
    /// matching minute cells; then upsert the meta int64s (the caller's byte offset and inode). Any
    /// error rolls the whole batch back, so a persisted offset never advances past unrecorded tokens.
    /// Returns the samples that were newly recorded (from keys inserted here), for the caller to emit.
    @discardableResult
    public func ingest(events: [AIIngestEvent], meta: [(String, Int64)]) throws -> [Sample] {
        guard !events.isEmpty || !meta.isEmpty else { return [] }
        return try queue.sync {
            let seenDay = DayBucket.dayEpoch(for: Date())
            try exec("BEGIN IMMEDIATE;")
            do {
                let seenStmt = try prepare(
                    "INSERT OR IGNORE INTO ai_seen (dedup_key, day_epoch) VALUES (?, ?);"
                )
                defer { sqlite3_finalize(seenStmt) }
                let sampleStmt = try prepare("""
                    INSERT INTO samples (day_epoch, minute, kind, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT (day_epoch, minute, kind)
                    DO UPDATE SET value = value + excluded.value;
                    """)
                defer { sqlite3_finalize(sampleStmt) }
                let metaStmt = try prepare("""
                    INSERT INTO meta (key, ival) VALUES (?, ?)
                    ON CONFLICT (key) DO UPDATE SET ival = excluded.ival;
                    """)
                defer { sqlite3_finalize(metaStmt) }

                var recorded: [Sample] = []
                for event in events {
                    bindText(seenStmt, 1, event.dedupKey)
                    sqlite3_bind_int64(seenStmt, 2, seenDay)
                    let seenRc = sqlite3_step(seenStmt)
                    guard seenRc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: seenRc) }
                    let newlySeen = sqlite3_changes(db) > 0
                    sqlite3_reset(seenStmt)
                    sqlite3_clear_bindings(seenStmt)
                    guard newlySeen else { continue }

                    for sample in event.samples {
                        let bucket = DayBucket(date: sample.timestamp)
                        sqlite3_bind_int64(sampleStmt, 1, bucket.dayEpoch)
                        sqlite3_bind_int(sampleStmt, 2, bucket.minute)
                        bindText(sampleStmt, 3, sample.kind.rawValue)
                        sqlite3_bind_int64(sampleStmt, 4, sample.value)
                        let rc = sqlite3_step(sampleStmt)
                        guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
                        sqlite3_reset(sampleStmt)
                        sqlite3_clear_bindings(sampleStmt)
                    }
                    recorded.append(contentsOf: event.samples)
                }

                for (key, value) in meta {
                    bindText(metaStmt, 1, key)
                    sqlite3_bind_int64(metaStmt, 2, value)
                    let rc = sqlite3_step(metaStmt)
                    guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
                    sqlite3_reset(metaStmt)
                    sqlite3_clear_bindings(metaStmt)
                }

                try exec("COMMIT;")
                return recorded
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Reads

    /// Sums every minute cell for `dayEpoch`, grouped by kind. Kinds absent from the day are
    /// absent from the result rather than zero.
    public func totals(forDayEpoch dayEpoch: Int64) throws -> [MetricKind: Int64] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT kind, SUM(value) FROM samples
                WHERE day_epoch = ?
                GROUP BY kind;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            var result: [MetricKind: Int64] = [:]
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    guard let raw = sqlite3_column_text(stmt, 0) else { continue }
                    // Ignore rows written by a future build whose kind this version doesn't know.
                    guard let kind = MetricKind(rawValue: String(cString: raw)) else { continue }
                    result[kind] = sqlite3_column_int64(stmt, 1)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    /// Sums every minute cell for each day in `days`, grouped by day and kind, in one query. Days and
    /// kinds absent from the samples are absent from the result rather than zero. Used by the margin
    /// engine (trailing days) and the General Ledger without a query per day.
    public func totals(forDayEpochs days: [Int64]) throws -> [Int64: [MetricKind: Int64]] {
        guard !days.isEmpty else { return [:] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: days.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT day_epoch, kind, SUM(value) FROM samples
                WHERE day_epoch IN (\(placeholders))
                GROUP BY day_epoch, kind;
                """)
            defer { sqlite3_finalize(stmt) }
            for (i, day) in days.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), day)
            }
            var result: [Int64: [MetricKind: Int64]] = [:]
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let day = sqlite3_column_int64(stmt, 0)
                    guard let raw = sqlite3_column_text(stmt, 1) else { continue }
                    guard let kind = MetricKind(rawValue: String(cString: raw)) else { continue }
                    result[day, default: [:]][kind] = sqlite3_column_int64(stmt, 2)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    /// The distinct days that hold any sample, newest first. The General Ledger lists these as the
    /// candidate accounting periods to review or close.
    public func dayEpochsWithData() throws -> [Int64] {
        try queue.sync {
            let stmt = try prepare("SELECT DISTINCT day_epoch FROM samples ORDER BY day_epoch DESC;")
            defer { sqlite3_finalize(stmt) }
            return try collectInt64Column(stmt)
        }
    }

    /// Per-kind totals summed across all history, the all-history trial balance shown in the right
    /// rail. Kinds never recorded are absent from the result.
    public func trialBalance() throws -> [MetricKind: Int64] {
        try queue.sync {
            let stmt = try prepare("SELECT kind, SUM(value) FROM samples GROUP BY kind;")
            defer { sqlite3_finalize(stmt) }
            var result: [MetricKind: Int64] = [:]
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    guard let raw = sqlite3_column_text(stmt, 0) else { continue }
                    guard let kind = MetricKind(rawValue: String(cString: raw)) else { continue }
                    result[kind] = sqlite3_column_int64(stmt, 1)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    /// A single minute cell's storage coordinates, used to line the fetched rows back up with the
    /// requested window positions regardless of how many days the window spans.
    private struct MinuteCoord: Hashable {
        let dayEpoch: Int64
        let minute: Int32
    }

    /// The last `count` completed minute buckets for each requested kind, oldest first, ending at the
    /// minute just before `reference`. The reference's own (still in-progress) minute is excluded, so a
    /// bucket only appears once it is finished. Empty minutes read as zero, and the window crosses local
    /// midnight correctly because every target minute is resolved through `DayBucket`, exactly like the
    /// write path. Runs one indexed range query per distinct day the window touches (one or two for a
    /// normal window), never a full-table scan.
    public func minuteSeries(
        kinds: [MetricKind],
        count: Int,
        endingBefore reference: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [MetricKind: [Int64]] {
        guard count > 0, !kinds.isEmpty else {
            return Dictionary(uniqueKeysWithValues: kinds.map { ($0, [Int64]()) })
        }

        // Walk back one wall-clock minute at a time from the start of the reference's (in-progress)
        // minute, bucketing each step through `DayBucket` so the day boundary is handled identically to
        // the write path. `targets` ends up oldest-first: index 0 is the furthest-back minute.
        let refMinuteStart = (reference.timeIntervalSince1970 / 60).rounded(.down) * 60
        var targets: [MinuteCoord] = []
        targets.reserveCapacity(count)
        for i in 0..<count {
            let stepsBack = count - i
            let date = Date(timeIntervalSince1970: refMinuteStart - Double(stepsBack) * 60)
            let bucket = DayBucket(date: date, calendar: calendar)
            targets.append(MinuteCoord(dayEpoch: bucket.dayEpoch, minute: bucket.minute))
        }

        // Group the targets by day so each day is fetched with one indexed range query over its
        // contiguous minute span rather than a scan.
        var spanByDay: [Int64: (lo: Int32, hi: Int32)] = [:]
        for target in targets {
            if let span = spanByDay[target.dayEpoch] {
                spanByDay[target.dayEpoch] = (Swift.min(span.lo, target.minute),
                                              Swift.max(span.hi, target.minute))
            } else {
                spanByDay[target.dayEpoch] = (target.minute, target.minute)
            }
        }

        return try queue.sync {
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT minute, kind, value FROM samples
                WHERE day_epoch = ? AND minute BETWEEN ? AND ? AND kind IN (\(placeholders));
                """)
            defer { sqlite3_finalize(stmt) }

            var fetched: [MinuteCoord: [MetricKind: Int64]] = [:]
            for (day, span) in spanByDay {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, day)
                sqlite3_bind_int(stmt, 2, span.lo)
                sqlite3_bind_int(stmt, 3, span.hi)
                for (i, kind) in kinds.enumerated() {
                    bindText(stmt, Int32(4 + i), kind.rawValue)
                }
                while true {
                    let rc = sqlite3_step(stmt)
                    if rc == SQLITE_ROW {
                        let minute = sqlite3_column_int(stmt, 0)
                        guard let raw = sqlite3_column_text(stmt, 1) else { continue }
                        guard let kind = MetricKind(rawValue: String(cString: raw)) else { continue }
                        let coord = MinuteCoord(dayEpoch: day, minute: minute)
                        fetched[coord, default: [:]][kind] = sqlite3_column_int64(stmt, 2)
                    } else if rc == SQLITE_DONE {
                        break
                    } else {
                        throw SQLiteError.from(db: db, code: rc)
                    }
                }
            }

            var result: [MetricKind: [Int64]] = [:]
            for kind in kinds {
                result[kind] = targets.map { fetched[$0]?[kind] ?? 0 }
            }
            return result
        }
    }

    // MARK: - Reconciliations

    /// Posts a day's immutable receipt. Because `day_epoch` is the primary key, a second attempt on an
    /// already-posted day inserts nothing and returns `false`, enforcing the "a day closes exactly
    /// once" rule without an error. Returns `true` when the row was newly written.
    @discardableResult
    public func insertReconciliation(_ reconciliation: Reconciliation) throws -> Bool {
        try queue.sync {
            let stmt = try prepare("""
                INSERT OR IGNORE INTO reconciliations
                    (day_epoch, closed_at, receipt_text, content_hash, stamp, comment)
                VALUES (?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, reconciliation.dayEpoch)
            sqlite3_bind_int64(stmt, 2, reconciliation.closedAt)
            bindText(stmt, 3, reconciliation.receiptText)
            bindText(stmt, 4, reconciliation.contentHash)
            bindText(stmt, 5, reconciliation.stamp)
            bindText(stmt, 6, reconciliation.comment)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
            return sqlite3_changes(db) > 0
        }
    }

    /// The stored reconciliation for `dayEpoch`, or nil when the day has not been closed.
    public func reconciliation(forDayEpoch dayEpoch: Int64) throws -> Reconciliation? {
        try queue.sync {
            let stmt = try prepare("""
                SELECT day_epoch, closed_at, receipt_text, content_hash, stamp, comment
                FROM reconciliations WHERE day_epoch = ?;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                return Reconciliation(
                    dayEpoch: sqlite3_column_int64(stmt, 0),
                    closedAt: sqlite3_column_int64(stmt, 1),
                    receiptText: columnText(stmt, 2),
                    contentHash: columnText(stmt, 3),
                    stamp: columnText(stmt, 4),
                    comment: columnText(stmt, 5)
                )
            } else if rc == SQLITE_DONE {
                return nil
            } else {
                throw SQLiteError.from(db: db, code: rc)
            }
        }
    }

    /// Every posted day's epoch, newest first, for binding the ledger's back-book.
    public func reconciledDayEpochs() throws -> [Int64] {
        try queue.sync {
            let stmt = try prepare("SELECT day_epoch FROM reconciliations ORDER BY day_epoch DESC;")
            defer { sqlite3_finalize(stmt) }
            return try collectInt64Column(stmt)
        }
    }

    /// Every posted day's stamp keyed by its epoch, so the General Ledger can label its period list in
    /// one query rather than reading each day's full receipt.
    public func reconciledStamps() throws -> [Int64: String] {
        try queue.sync {
            let stmt = try prepare("SELECT day_epoch, stamp FROM reconciliations;")
            defer { sqlite3_finalize(stmt) }
            var result: [Int64: String] = [:]
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    result[sqlite3_column_int64(stmt, 0)] = columnText(stmt, 1)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    // MARK: - Meta

    public func metaInt(_ key: String) throws -> Int64? {
        try queue.sync {
            let stmt = try prepare("SELECT ival FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
                return sqlite3_column_int64(stmt, 0)
            } else if rc == SQLITE_DONE {
                return nil
            } else {
                throw SQLiteError.from(db: db, code: rc)
            }
        }
    }

    public func setMetaInt(_ key: String, _ value: Int64) throws {
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO meta (key, ival) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET ival = excluded.ival;
                """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            sqlite3_bind_int64(stmt, 2, value)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
        }
    }

    public func metaString(_ key: String) throws -> String? {
        try queue.sync {
            let stmt = try prepare("SELECT sval FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 0) else { return nil }
                return String(cString: raw)
            } else if rc == SQLITE_DONE {
                return nil
            } else {
                throw SQLiteError.from(db: db, code: rc)
            }
        }
    }

    public func setMetaString(_ key: String, _ value: String) throws {
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO meta (key, sval) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET sval = excluded.sval;
                """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
        }
    }

    /// Every meta key beginning with `prefix`. Used to reconcile per-file offset/inode rows against
    /// the files that still exist. LIKE wildcards in the prefix are escaped so it matches literally.
    public func metaKeys(withPrefix prefix: String) throws -> [String] {
        try queue.sync {
            let stmt = try prepare("SELECT key FROM meta WHERE key LIKE ? ESCAPE '\\';")
            defer { sqlite3_finalize(stmt) }
            let escaped = prefix
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            bindText(stmt, 1, escaped + "%")
            var keys: [String] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    if let raw = sqlite3_column_text(stmt, 0) { keys.append(String(cString: raw)) }
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return keys
        }
    }

    public func deleteMeta(key: String) throws {
        try queue.sync {
            let stmt = try prepare("DELETE FROM meta WHERE key = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
        }
    }

    // MARK: - AI dedup ledger

    /// Records a dedup key. Returns `true` when it was newly inserted, `false` when it was already
    /// present. One atomic `INSERT OR IGNORE` plus a `changes()` check decides which.
    public func markSeen(dedupKey: String, dayEpoch: Int64) throws -> Bool {
        try queue.sync {
            let stmt = try prepare("""
                INSERT OR IGNORE INTO ai_seen (dedup_key, day_epoch) VALUES (?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, dedupKey)
            sqlite3_bind_int64(stmt, 2, dayEpoch)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
            return sqlite3_changes(db) > 0
        }
    }

    /// Drops dedup entries whose `day_epoch` is older than `days` before today. Best-effort
    /// maintenance called on open, so a failure here never blocks startup.
    public func pruneAISeen(olderThanDays days: Int) {
        queue.sync {
            let today = DayBucket.dayEpoch(for: Date())
            let cutoff = today - Int64(days) * 86_400
            try? exec("DELETE FROM ai_seen WHERE day_epoch < \(cutoff);")
        }
    }

    // MARK: - Raw SQLite helpers

    private func configure() throws {
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA busy_timeout = 5000;")
    }

    private func exec(_ sql: String) throws {
        try execSQL(db, sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError.from(db: db, code: rc) }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    /// Reads a TEXT column, treating SQL NULL as the empty string. The reconciliation columns are all
    /// declared NOT NULL, so NULL never actually occurs here.
    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: raw)
    }

    /// Drains a single-column INTEGER result set into an array. Assumes it runs on `queue`.
    private func collectInt64Column(_ stmt: OpaquePointer) throws -> [Int64] {
        var values: [Int64] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                values.append(sqlite3_column_int64(stmt, 0))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.from(db: db, code: rc)
            }
        }
        return values
    }
}
