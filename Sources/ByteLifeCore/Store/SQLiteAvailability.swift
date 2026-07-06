import SQLite3

/// Confirms the system SQLite3 module links and resolves. The real store lands in a later stage.
/// Referencing `sqlite3_libversion` forces the linker to bind the C library at build time.
public enum SQLiteAvailability {
    /// The linked SQLite library version string, e.g. "3.43.2".
    public static var version: String {
        String(cString: sqlite3_libversion())
    }
}
