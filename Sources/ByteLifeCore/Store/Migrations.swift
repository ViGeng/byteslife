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
    static let currentVersion: Int32 = 1

    static func migrate(_ db: OpaquePointer) throws {
        if try userVersion(db) < 1 {
            try applyV1(db)
            try setUserVersion(db, 1)
        }
    }

    private static func applyV1(_ db: OpaquePointer) throws {
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
