import Foundation
import SQLite3

/// Tells SQLite to copy a bound value immediately, because the Swift string backing it is a
/// temporary the C call outlives. SQLITE_STATIC would let SQLite read freed memory here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Fine-grained attribution for one ingested AI usage event: which source produced it, which model
/// answered, the session it belongs to, and the event's own timestamp. Carried alongside the additive
/// samples so the SAME atomic ingest that books tokens also upserts the per-model day totals and the
/// session's first/last timestamps. A missing model is normalized to "unknown" so the model ledger is
/// never keyed on an empty string.
///
/// Backfill honesty: attribution is booked only for a NEWLY-seen event, exactly like its samples. The
/// `ai_models` and `ai_sessions` ledgers therefore fill going forward, for events ingested from now on.
/// Already-ingested history is not retroactively attributed, because the sources' dedup keys and byte
/// offsets keep old transcript content from being re-read. This stage forces no re-scan.
public struct AIUsageAttribution: Equatable, Sendable {
    /// Short, stable source key (for example "claudeCode", "codex", "gemini").
    public let source: String
    /// The answering model, or "unknown" when the transcript line carried none.
    public let model: String
    /// The session identity this event belongs to; empty means the source could not name a session,
    /// in which case only the per-model total is booked and no session row is written.
    public let sessionId: String
    /// The event's own timestamp: the day attribution for the model total and the session's
    /// first/last-seen bounds both derive from it.
    public let timestamp: Date

    public init(source: String, model: String, sessionId: String, timestamp: Date) {
        self.source = source
        self.model = model.isEmpty ? "unknown" : model
        self.sessionId = sessionId
        self.timestamp = timestamp
    }
}

/// One AI usage record to ingest atomically: a dedup key, the additive samples it contributes, and an
/// optional fine-grained attribution. The store records the samples (and, when present, the model and
/// session rows) only when the key is newly seen, so the whole `ingest` batch stays exactly-once even
/// if it is retried after a failure. A nil `attribution` books only the samples, exactly as before.
public struct AIIngestEvent: Equatable, Sendable {
    public let dedupKey: String
    public let samples: [Sample]
    public let attribution: AIUsageAttribution?

    public init(dedupKey: String, samples: [Sample], attribution: AIUsageAttribution? = nil) {
        self.dedupKey = dedupKey
        self.samples = samples
        self.attribution = attribution
    }
}

/// A day's (or period's) token total for one source+model pair, read back from the `ai_models` ledger.
public struct AIModelTotal: Equatable, Sendable {
    public let source: String
    public let model: String
    public let input: Int64
    public let output: Int64
    public let cacheCreation: Int64
    public let cacheRead: Int64

    public init(source: String, model: String, input: Int64, output: Int64,
                cacheCreation: Int64, cacheRead: Int64) {
        self.source = source
        self.model = model
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    /// The sources whose recorded `input` channel already CONTAINS their `cacheRead` tokens: Codex's
    /// `input_tokens` and Gemini's per-message `input` both include the cached prompt portion (verified
    /// against real transcripts, where total = input + output), while Claude transcripts book the cache
    /// channels separately from input. Readers must not add `cacheRead` on top of `input` for these rows.
    public static let cacheInclusiveInputSources: Set<String> = ["codex", "gemini"]

    /// Whether this row's `input` already contains its `cacheRead` tokens (see
    /// `cacheInclusiveInputSources`).
    public var inputIncludesCacheRead: Bool { Self.cacheInclusiveInputSources.contains(source) }

    /// The uncached prompt tokens: `input` net of the cached subset for cache-inclusive sources, `input`
    /// verbatim otherwise. Clamped at zero so a malformed row can never book negative tokens.
    public var uncachedInput: Int64 { inputIncludesCacheRead ? max(0, input - cacheRead) : input }

    /// Every channel counted exactly once (a cache-inclusive source's `cacheRead` lives inside `input`),
    /// the natural weight for ranking the top models.
    public var total: Int64 { uncachedInput + output + cacheCreation + cacheRead }
}

/// Session statistics for a single day: how many sessions opened that day and how long they ran.
/// A session's length is `last_seen - first_seen` in seconds; the averages are zero when no session
/// opened on the day.
public struct AISessionStats: Equatable, Sendable {
    public let count: Int
    public let averageLength: Int64
    public let longestLength: Int64

    public init(count: Int, averageLength: Int64, longestLength: Int64) {
        self.count = count
        self.averageLength = averageLength
        self.longestLength = longestLength
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
    /// matching minute cells AND, when the event carries an attribution, upsert its per-model day total
    /// and its session's first/last timestamps; then upsert the meta int64s (the caller's byte offset
    /// and inode). Every write shares the one transaction, so any error rolls the whole batch back and a
    /// persisted offset never advances past unrecorded tokens, model rows, or session bounds. Returns the
    /// samples that were newly recorded (from keys inserted here), for the caller to emit.
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
                // Per-model day total: accumulate every channel additively on conflict.
                let modelStmt = try prepare("""
                    INSERT INTO ai_models
                        (day_epoch, source, model, input, output, cache_creation, cache_read)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (day_epoch, source, model) DO UPDATE SET
                        input          = input          + excluded.input,
                        output         = output         + excluded.output,
                        cache_creation = cache_creation + excluded.cache_creation,
                        cache_read     = cache_read     + excluded.cache_read;
                    """)
                defer { sqlite3_finalize(modelStmt) }
                // Session bounds: keep the earliest first_seen and the latest last_seen, and attribute
                // the session to the day of its (possibly newly earlier) first sighting.
                let sessionStmt = try prepare("""
                    INSERT INTO ai_sessions (session_id, source, first_seen, last_seen, day_epoch)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (session_id) DO UPDATE SET
                        first_seen = MIN(first_seen, excluded.first_seen),
                        last_seen  = MAX(last_seen, excluded.last_seen),
                        day_epoch  = CASE WHEN excluded.first_seen < first_seen
                                          THEN excluded.day_epoch ELSE day_epoch END;
                    """)
                defer { sqlite3_finalize(sessionStmt) }
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

                    if let attribution = event.attribution {
                        try upsertAttributionLocked(attribution, samples: event.samples,
                                                    modelStmt: modelStmt, sessionStmt: sessionStmt)
                    }
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

    /// Upserts one newly-seen event's fine-grained attribution using the already-prepared statements,
    /// inside the caller's open transaction. The per-model day total sums each token channel from the
    /// event's own samples (so the model ledger and the samples table can never disagree); the session
    /// row records the event timestamp as both a first- and last-seen candidate. A source-less
    /// attribution books nothing; a session-less one books only the model total. Must run on `queue`.
    private func upsertAttributionLocked(
        _ attribution: AIUsageAttribution,
        samples: [Sample],
        modelStmt: OpaquePointer,
        sessionStmt: OpaquePointer
    ) throws {
        guard !attribution.source.isEmpty else { return }
        let dayEpoch = DayBucket.dayEpoch(for: attribution.timestamp)
        let unixSeconds = Int64(attribution.timestamp.timeIntervalSince1970.rounded(.down))

        var input: Int64 = 0, output: Int64 = 0, cacheCreation: Int64 = 0, cacheRead: Int64 = 0
        for sample in samples {
            switch sample.kind {
            case .aiInputTokens: input += sample.value
            case .aiOutputTokens: output += sample.value
            case .aiCacheCreationTokens: cacheCreation += sample.value
            case .aiCacheReadTokens: cacheRead += sample.value
            default: break
            }
        }

        sqlite3_bind_int64(modelStmt, 1, dayEpoch)
        bindText(modelStmt, 2, attribution.source)
        bindText(modelStmt, 3, attribution.model)
        sqlite3_bind_int64(modelStmt, 4, input)
        sqlite3_bind_int64(modelStmt, 5, output)
        sqlite3_bind_int64(modelStmt, 6, cacheCreation)
        sqlite3_bind_int64(modelStmt, 7, cacheRead)
        let modelRc = sqlite3_step(modelStmt)
        guard modelRc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: modelRc) }
        sqlite3_reset(modelStmt)
        sqlite3_clear_bindings(modelStmt)

        guard !attribution.sessionId.isEmpty else { return }
        bindText(sessionStmt, 1, attribution.sessionId)
        bindText(sessionStmt, 2, attribution.source)
        sqlite3_bind_int64(sessionStmt, 3, unixSeconds)
        sqlite3_bind_int64(sessionStmt, 4, unixSeconds)
        sqlite3_bind_int64(sessionStmt, 5, dayEpoch)
        let sessionRc = sqlite3_step(sessionStmt)
        guard sessionRc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: sessionRc) }
        sqlite3_reset(sessionStmt)
        sqlite3_clear_bindings(sessionStmt)
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

    /// The 24 hour buckets for `dayEpoch` and each requested kind, each bucket summed from that day's
    /// minute rows (bucket = minute / 60) and zero where no sample fell in it. The result always holds
    /// exactly 24 values per requested kind, so a requested kind absent from the day reads as all zeros
    /// rather than being missing. One indexed range query over the day's contiguous rows on the
    /// (day_epoch, minute, kind) primary key, never a full-table scan. Feeds the day dashboard's hourly
    /// bars via the pure `DayStory` model.
    public func hourlySeries(kinds: [MetricKind], dayEpoch: Int64) throws -> [MetricKind: [Int64]] {
        guard !kinds.isEmpty else { return [:] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT minute, kind, value FROM samples
                WHERE day_epoch = ? AND kind IN (\(placeholders));
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            for (i, kind) in kinds.enumerated() {
                bindText(stmt, Int32(2 + i), kind.rawValue)
            }
            var result = Dictionary(
                uniqueKeysWithValues: kinds.map { ($0, [Int64](repeating: 0, count: 24)) }
            )
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let hour = Int(sqlite3_column_int(stmt, 0)) / 60
                    guard hour >= 0, hour < 24 else { continue }
                    guard let raw = sqlite3_column_text(stmt, 1) else { continue }
                    guard let kind = MetricKind(rawValue: String(cString: raw)) else { continue }
                    result[kind]?[hour] += sqlite3_column_int64(stmt, 2)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    /// The per-minute values for a single kind on a single day, in ascending minute order. Only minutes
    /// that carried a sample appear (absent minutes are omitted, never zero-filled), which is exactly what
    /// the typing-cadence model reads: keystroke cells are only ever written with a positive value, so the
    /// result is the day's non-zero keystroke minutes. One indexed range query over the day's contiguous
    /// rows on the (day_epoch, minute, kind) primary key, never a full-table scan. Feeds `TypingCadence`
    /// on the Back Office day story.
    public func dayMinuteSeries(kind: MetricKind, dayEpoch: Int64) throws -> [Int64] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT value FROM samples
                WHERE day_epoch = ? AND kind = ?
                ORDER BY minute ASC;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            bindText(stmt, 2, kind.rawValue)
            return try collectInt64Column(stmt)
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

    // MARK: - Focus (per-app attention)

    /// UPSERT-accumulates `seconds` of foreground attention for `bundleId` on `dayEpoch`. The focus
    /// table carries the per-app dimension the single-dimensional samples table cannot, so App Focus
    /// posts here rather than through `record`. Non-positive seconds are a no-op.
    public func recordFocus(dayEpoch: Int64, bundleId: String, seconds: Int64) throws {
        guard seconds > 0 else { return }
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO focus (day_epoch, bundle_id, seconds) VALUES (?, ?, ?)
                ON CONFLICT (day_epoch, bundle_id) DO UPDATE SET seconds = seconds + excluded.seconds;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            bindText(stmt, 2, bundleId)
            sqlite3_bind_int64(stmt, 3, seconds)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
        }
    }

    /// The day's most-focused apps, highest seconds first, capped at `limit`. Feeds the day story's
    /// top-apps memo and the panel's top-app chip.
    public func topFocus(dayEpoch: Int64, limit: Int) throws -> [(bundleId: String, seconds: Int64)] {
        guard limit > 0 else { return [] }
        return try queue.sync {
            let stmt = try prepare("""
                SELECT bundle_id, seconds FROM focus
                WHERE day_epoch = ?
                ORDER BY seconds DESC, bundle_id ASC
                LIMIT ?;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var result: [(bundleId: String, seconds: Int64)] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    result.append((columnText(stmt, 0), sqlite3_column_int64(stmt, 1)))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    /// Per-app focus seconds for each day in `days`, grouped by day and bundle id, in one query. Feeds the
    /// Back Office aggregate story, which merges the per-day rows into a period-wide top list in memory.
    /// Days and apps absent from the `focus` table are absent from the result rather than zero.
    public func focus(forDayEpochs days: [Int64]) throws -> [Int64: [String: Int64]] {
        guard !days.isEmpty else { return [:] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: days.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT day_epoch, bundle_id, seconds FROM focus
                WHERE day_epoch IN (\(placeholders));
                """)
            defer { sqlite3_finalize(stmt) }
            for (i, day) in days.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), day) }
            var result: [Int64: [String: Int64]] = [:]
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let day = sqlite3_column_int64(stmt, 0)
                    result[day, default: [:]][columnText(stmt, 1)] = sqlite3_column_int64(stmt, 2)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    // MARK: - Hosts seen (distinct remote hosts)

    /// Records a salted host hash for `dayEpoch`, returning `true` when it was newly seen that day.
    /// The hash is the only thing stored; the hostname is never persisted. Distinct-per-day is enforced
    /// by the composite primary key, so the caller can treat a `true` return as one new distinct host.
    @discardableResult
    public func markHostSeen(dayEpoch: Int64, hash: String) throws -> Bool {
        try queue.sync {
            let stmt = try prepare(
                "INSERT OR IGNORE INTO hosts_seen (day_epoch, host_hash) VALUES (?, ?);"
            )
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            bindText(stmt, 2, hash)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
            return sqlite3_changes(db) > 0
        }
    }

    /// The number of distinct remote hosts seen on `dayEpoch`, the Hosts Contacted metric.
    public func distinctHosts(dayEpoch: Int64) throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM hosts_seen WHERE day_epoch = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else { throw SQLiteError.from(db: db, code: rc) }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// The distinct-host count for each day in `days`, in one grouped query. Feeds the Back Office
    /// aggregate story, whose Hosts Contacted figure sums the per-day distinct counts. Days with no
    /// sightings are absent from the result rather than zero.
    public func distinctHosts(forDayEpochs days: [Int64]) throws -> [Int64: Int] {
        guard !days.isEmpty else { return [:] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: days.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT day_epoch, COUNT(*) FROM hosts_seen
                WHERE day_epoch IN (\(placeholders))
                GROUP BY day_epoch;
                """)
            defer { sqlite3_finalize(stmt) }
            for (i, day) in days.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), day) }
            var result: [Int64: Int] = [:]
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    result[sqlite3_column_int64(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return result
        }
    }

    // MARK: - AI model & session ledgers

    /// The per-source, per-model token totals booked on `dayEpoch`, one row per source+model pair.
    /// One indexed range query over the day's contiguous rows on the (day_epoch, source, model) primary
    /// key. Rows are returned heaviest first (by total tokens) so the caller can take the top models
    /// directly. A day with no AI usage returns an empty array.
    public func aiModelTotals(dayEpoch: Int64) throws -> [AIModelTotal] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT source, model, input, output, cache_creation, cache_read
                FROM ai_models WHERE day_epoch = ?;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            return try collectModelTotals(stmt)
        }
    }

    /// The per-source, per-model token totals summed across every day in `days`, grouped so each
    /// source+model pair appears once. One indexed query using the (day_epoch, ...) primary key for the
    /// `IN` range. Rows are returned heaviest first. Feeds the Back Office aggregate COGNITION card.
    public func aiModelTotals(dayEpochs days: [Int64]) throws -> [AIModelTotal] {
        guard !days.isEmpty else { return [] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: days.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT source, model,
                       SUM(input), SUM(output), SUM(cache_creation), SUM(cache_read)
                FROM ai_models WHERE day_epoch IN (\(placeholders))
                GROUP BY source, model;
                """)
            defer { sqlite3_finalize(stmt) }
            for (i, day) in days.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), day) }
            return try collectModelTotals(stmt)
        }
    }

    /// Drains a six-column (source, model, input, output, cache_creation, cache_read) result set into
    /// `AIModelTotal`s, sorted heaviest total first with source+model as a stable tiebreak. On `queue`.
    private func collectModelTotals(_ stmt: OpaquePointer) throws -> [AIModelTotal] {
        var rows: [AIModelTotal] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(AIModelTotal(
                    source: columnText(stmt, 0),
                    model: columnText(stmt, 1),
                    input: sqlite3_column_int64(stmt, 2),
                    output: sqlite3_column_int64(stmt, 3),
                    cacheCreation: sqlite3_column_int64(stmt, 4),
                    cacheRead: sqlite3_column_int64(stmt, 5)
                ))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.from(db: db, code: rc)
            }
        }
        return rows.sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.model < $1.model
        }
    }

    /// Session statistics for the sessions whose FIRST sighting fell on `dayEpoch`: how many opened,
    /// their average length, and the longest, each length being `last_seen - first_seen` in seconds.
    /// One indexed lookup via the `ai_sessions_by_day` index. A day with no new session reports zeros.
    public func aiSessionStats(dayEpoch: Int64) throws -> AISessionStats {
        try queue.sync {
            let stmt = try prepare("""
                SELECT COUNT(*),
                       CAST(AVG(last_seen - first_seen) AS INTEGER),
                       MAX(last_seen - first_seen)
                FROM ai_sessions WHERE day_epoch = ?;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else { throw SQLiteError.from(db: db, code: rc) }
            let count = Int(sqlite3_column_int64(stmt, 0))
            // AVG and MAX are SQL NULL when no row matched; read them as zero.
            let average = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 1)
            let longest = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 2)
            return AISessionStats(count: count, averageLength: average, longestLength: longest)
        }
    }

    // MARK: - Gauges (per-minute sensor readings)

    /// Records one gauge READING for a minute cell, REPLACING any prior reading in that cell because a
    /// gauge is a level, not an accumulator. Minutes outside the day (0..<1440) are rejected as a no-op.
    public func recordGauge(dayEpoch: Int64, minute: Int32, gauge: String, value: Int64) throws {
        guard minute >= 0, minute < 1440 else { return }
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO gauges (day_epoch, minute, gauge, value) VALUES (?, ?, ?, ?)
                ON CONFLICT (day_epoch, minute, gauge) DO UPDATE SET value = excluded.value;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            sqlite3_bind_int(stmt, 2, minute)
            bindText(stmt, 3, gauge)
            sqlite3_bind_int64(stmt, 4, value)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw SQLiteError.from(db: db, code: rc) }
        }
    }

    /// The day's readings for one `gauge` as a 1440-slot minute series, `nil` where no reading was taken
    /// (a gap is honestly absent, never zero, since zero is a real reading). One indexed range query over
    /// the day's contiguous rows on the (day_epoch, minute, gauge) primary key, filtering the gauge in the
    /// scan. Feeds the Back Office SENSORS curves.
    public func gaugeSeries(gauge: String, dayEpoch: Int64) throws -> [Int64?] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT minute, value FROM gauges WHERE day_epoch = ? AND gauge = ?;
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, dayEpoch)
            bindText(stmt, 2, gauge)
            var series = [Int64?](repeating: nil, count: 1440)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    let minute = Int(sqlite3_column_int(stmt, 0))
                    guard minute >= 0, minute < 1440 else { continue }
                    series[minute] = sqlite3_column_int64(stmt, 1)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.from(db: db, code: rc)
                }
            }
            return series
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
