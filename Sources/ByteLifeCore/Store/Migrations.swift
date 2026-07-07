import SQLite3

/// Runs a SQL string that yields no caller-consumed rows, throwing `SQLiteError` on failure.
/// Shared by the migrator and the store for DDL and transaction control.
func execSQL(_ db: OpaquePointer, _ sql: String) throws {
    var errmsg: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
    defer { sqlite3_free(errmsg) }
    guard rc == SQLITE_OK else {
        let message = errmsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
        throw SQLiteError(code: rc, message: message)
    }
}

/// Creates and upgrades the schema, keyed on SQLite's built-in `user_version`. Reopening an
/// up-to-date database is a no-op because the version already matches.
enum Migrations {
    /// Schema version this build targets. Bump alongside a new `applyVN` step.
    static let currentVersion: Int32 = 4

    static func migrate(_ db: OpaquePointer) throws {
        if try userVersion(db) < 1 {
            try applyV1(db)
            try setUserVersion(db, 1)
        }
        if try userVersion(db) < 2 {
            try applyV2(db)
            try setUserVersion(db, 2)
        }
        if try userVersion(db) < 3 {
            try applyV3(db)
            try setUserVersion(db, 3)
        }
        if try userVersion(db) < 4 {
            try applyV4(db)
            try setUserVersion(db, 4)
        }
    }

    // `applyV1` through `applyV4` are visible to the migration tests, each of which builds a genuine
    // populated prior-version store and reopens it through `migrate` to prove the next step is additive.
    static func applyV1(_ db: OpaquePointer) throws {
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS samples (
                day_epoch INTEGER NOT NULL,
                minute    INTEGER NOT NULL,
                kind      TEXT    NOT NULL,
                value     INTEGER NOT NULL,
                PRIMARY KEY (day_epoch, minute, kind)
            ) WITHOUT ROWID;
            """)
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS meta (
                key  TEXT PRIMARY KEY,
                ival INTEGER,
                sval TEXT
            );
            """)
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS ai_seen (
                dedup_key TEXT PRIMARY KEY,
                day_epoch INTEGER NOT NULL
            );
            """)
    }

    /// Additive step for the Ledger's Reconcile ritual: a `reconciliations` table binding each closed
    /// day to its immutable receipt. `day_epoch` is the primary key, so a day can be posted exactly
    /// once. Purely additive, leaving every v1 table and row untouched.
    static func applyV2(_ db: OpaquePointer) throws {
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS reconciliations (
                day_epoch    INTEGER PRIMARY KEY,
                closed_at    INTEGER NOT NULL,
                receipt_text TEXT    NOT NULL,
                content_hash TEXT    NOT NULL,
                stamp        TEXT    NOT NULL,
                comment      TEXT    NOT NULL
            );
            """)
    }

    /// Additive step for the wider estate. `focus` is the per-app attention ledger the samples table
    /// cannot hold (it is single-dimensional), keyed by day and bundle id with accumulating seconds.
    /// `hosts_seen` is a per-day dedup set of salted remote-host hashes; the metric is its distinct
    /// count and no hostname is ever stored. Purely additive, leaving every v1 and v2 table untouched.
    static func applyV3(_ db: OpaquePointer) throws {
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS focus (
                day_epoch INTEGER NOT NULL,
                bundle_id TEXT    NOT NULL,
                seconds   INTEGER NOT NULL,
                PRIMARY KEY (day_epoch, bundle_id)
            ) WITHOUT ROWID;
            """)
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS hosts_seen (
                day_epoch INTEGER NOT NULL,
                host_hash TEXT    NOT NULL,
                PRIMARY KEY (day_epoch, host_hash)
            ) WITHOUT ROWID;
            """)
    }

    /// Additive step for fine-grained AI and sampled sensor curves. `ai_models` is the per-day,
    /// per-source, per-model token ledger the single-dimensional samples table cannot hold, accumulated
    /// with UPSERT. `ai_sessions` records each AI session's first/last activity, attributed to the day of
    /// its first sighting (indexed on `day_epoch` so the day-scoped stats query stays a single range).
    /// `gauges` holds per-minute sensor READINGS (temperature, charge, lux, and so on) that are replaced,
    /// not accumulated, because a gauge is a level and not a counter. Purely additive, leaving every v1
    /// through v3 table untouched.
    static func applyV4(_ db: OpaquePointer) throws {
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS ai_models (
                day_epoch      INTEGER NOT NULL,
                source         TEXT    NOT NULL,
                model          TEXT    NOT NULL,
                input          INTEGER NOT NULL,
                output         INTEGER NOT NULL,
                cache_creation INTEGER NOT NULL,
                cache_read     INTEGER NOT NULL,
                PRIMARY KEY (day_epoch, source, model)
            ) WITHOUT ROWID;
            """)
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS ai_sessions (
                session_id TEXT PRIMARY KEY,
                source     TEXT    NOT NULL,
                first_seen INTEGER NOT NULL,
                last_seen  INTEGER NOT NULL,
                day_epoch  INTEGER NOT NULL
            );
            """)
        try execSQL(db, "CREATE INDEX IF NOT EXISTS ai_sessions_by_day ON ai_sessions (day_epoch);")
        try execSQL(db, """
            CREATE TABLE IF NOT EXISTS gauges (
                day_epoch INTEGER NOT NULL,
                minute    INTEGER NOT NULL,
                gauge     TEXT    NOT NULL,
                value     INTEGER NOT NULL,
                PRIMARY KEY (day_epoch, minute, gauge)
            ) WITHOUT ROWID;
            """)
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw SQLiteError.from(db: db, code: sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SQLiteError.from(db: db, code: sqlite3_errcode(db))
        }
        return sqlite3_column_int(stmt, 0)
    }

    private static func setUserVersion(_ db: OpaquePointer, _ version: Int32) throws {
        // PRAGMA does not accept bound parameters, so interpolate our own trusted integer.
        try execSQL(db, "PRAGMA user_version = \(version);")
    }
}
