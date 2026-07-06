import SQLite3

/// A failure surfaced by the SQLite C API, carrying the numeric result code and the
/// connection's last error message where one is available.
public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    /// Builds an error from a connection handle, reading its last error message.
    static func from(db: OpaquePointer?, code: Int32) -> SQLiteError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return SQLiteError(code: code, message: message)
    }

    public var description: String {
        "SQLiteError(code: \(code), message: \(message))"
    }
}
