import Foundation

/// Shared tuning and stat helpers for the file-watching AI sources (Codex, Claude Code, Gemini).
///
/// Every source discovers a whole tree of historical session transcripts. Installing a persistent
/// `O_EVTONLY` vnode watcher on each one is what exhausts file descriptors: this machine holds well over
/// a thousand Codex rollouts and several hundred Claude transcripts, and a launchd GUI app gets only a
/// 256 soft descriptor limit, so an unbounded watcher-per-file hits `EMFILE` and starves other fd users
/// (nettop's per-process pipes, the SQLite WAL). The fix is to watch only files whose content changed
/// recently and re-check the rest cheaply with a `stat` on each discovery pass.
enum AISourceWatch {
    /// A session file whose modification time is within this window earns a persistent vnode watcher;
    /// older files get none and are instead re-checked with a `stat` on each discovery pass. Two days is
    /// wide enough to keep every actively edited transcript live-tailed, narrow enough that the watched
    /// set stays a small fraction of a long history.
    static let recencyWindow: TimeInterval = 2 * 24 * 60 * 60

    /// Whether `path`'s modification time is within `recencyWindow` of `now`. A file that cannot be
    /// stat'd is treated as not recent, so it takes the cheap re-stat path rather than holding a watcher.
    static func isRecent(path: String, now: Date = Date()) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        return now.timeIntervalSince1970 - TimeInterval(status.st_mtimespec.tv_sec) <= recencyWindow
    }

    /// The size of the file at `path` in bytes, or nil when it cannot be stat'd. The offset-tailed
    /// sources compare it against the byte offset already consumed to decide whether an unwatched file
    /// has grown and needs re-tailing.
    static func fileSize(path: String) -> Int64? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Int64(status.st_size)
    }
}
