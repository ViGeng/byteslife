import Foundation

/// A resumable, byte-offset line reader for append-only logs such as Claude Code transcripts.
///
/// Given a persisted byte offset and the inode the offset was recorded against, `read` returns only
/// the complete lines that appeared since then plus the new offset to persist. A trailing partial
/// line (bytes with no terminating newline yet) is left unconsumed until its newline arrives, so a
/// half-written record is never parsed. Rotation (the file's inode changed) or truncation (the file
/// is now smaller than the offset) restarts the read from byte 0; upstream dedup keeps that from
/// re-counting anything.
public enum FileTailer {
    public struct Result: Equatable {
        /// Complete lines read since `offset`, newline stripped. Empty when only a partial line exists.
        public let lines: [String]
        /// The byte offset to persist and pass to the next call.
        public let newOffset: Int64
        /// The file's current inode, to persist and pass to the next call.
        public let inode: UInt64
        /// True when rotation or truncation forced the read back to byte 0.
        public let didReset: Bool
    }

    public enum TailError: Error, Equatable {
        case unreadable(String)
    }

    public static func read(path: String, offset: Int64, priorInode: UInt64) throws -> Result {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw TailError.unreadable(path)
        }
        defer { try? handle.close() }

        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw TailError.unreadable(path)
        }
        let inode = UInt64(status.st_ino)
        let size = Int64(status.st_size)

        // A changed inode means a different file behind the same path (rotation); a size below our
        // cursor means the file was truncated. Either way the old offset is meaningless, so restart
        // from the beginning. `priorInode == 0` marks "no prior inode", so it never triggers a reset.
        var start = offset
        var didReset = false
        if priorInode != 0 && inode != priorInode {
            start = 0
            didReset = true
        }
        if size < start {
            start = 0
            didReset = true
        }

        guard start < size else {
            return Result(lines: [], newOffset: size, inode: inode, didReset: didReset)
        }

        try handle.seek(toOffset: UInt64(start))
        let data = handle.readData(ofLength: Int(size - start))

        // Consume up to and including the last newline; anything after it is an unfinished line and
        // stays unread (newOffset advances only past the last complete line).
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            return Result(lines: [], newOffset: start, inode: inode, didReset: didReset)
        }
        let consumedCount = data.distance(from: data.startIndex, to: lastNewline) + 1
        let text = String(decoding: data.prefix(consumedCount), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The split after a trailing newline yields one empty tail element; drop it.
        if lines.last == "" { lines.removeLast() }

        return Result(
            lines: lines,
            newOffset: start + Int64(consumedCount),
            inode: inode,
            didReset: didReset
        )
    }
}
