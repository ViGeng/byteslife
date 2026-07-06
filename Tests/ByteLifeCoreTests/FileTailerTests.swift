import XCTest
@testable import ByteLifeCore

final class FileTailerTests: XCTestCase {
    private var dir: URL!
    private var path: String!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeTailerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("session.jsonl").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testReturnsOnlyCompleteLinesLeavingPartialUnconsumed() throws {
        try write("line1\nline2\npartial")
        let result = try FileTailer.read(path: path, offset: 0, priorInode: 0)
        XCTAssertEqual(result.lines, ["line1", "line2"])
        // Consumed up to the last newline; the partial tail is left behind.
        XCTAssertEqual(result.newOffset, Int64("line1\nline2\n".utf8.count))
        XCTAssertFalse(result.didReset)
    }

    func testPartialLineIsReadOnceItsNewlineArrives() throws {
        try write("line1\nline2\npartial")
        let first = try FileTailer.read(path: path, offset: 0, priorInode: 0)
        // Finish the partial line and add another.
        try append("-rest\nline3\n")
        let second = try FileTailer.read(path: path, offset: first.newOffset, priorInode: first.inode)
        XCTAssertEqual(second.lines, ["partial-rest", "line3"])
        XCTAssertFalse(second.didReset)
    }

    func testAppendReadsOnlyNewBytes() throws {
        try write("a\n")
        let first = try FileTailer.read(path: path, offset: 0, priorInode: 0)
        XCTAssertEqual(first.lines, ["a"])
        try append("b\nc\n")
        let second = try FileTailer.read(path: path, offset: first.newOffset, priorInode: first.inode)
        XCTAssertEqual(second.lines, ["b", "c"])
        XCTAssertEqual(second.newOffset, Int64("a\nb\nc\n".utf8.count))
    }

    func testNoNewBytesReturnsNothing() throws {
        try write("a\nb\n")
        let first = try FileTailer.read(path: path, offset: 0, priorInode: 0)
        let second = try FileTailer.read(path: path, offset: first.newOffset, priorInode: first.inode)
        XCTAssertTrue(second.lines.isEmpty)
        XCTAssertEqual(second.newOffset, first.newOffset)
        XCTAssertFalse(second.didReset)
    }

    func testTruncationResetsToZeroKeepingInode() throws {
        try write("aaaa\nbbbb\ncccc\n")
        let first = try FileTailer.read(path: path, offset: 0, priorInode: 0)
        XCTAssertEqual(first.lines.count, 3)

        // Truncate in place so the inode is preserved but the file is now smaller than our offset.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("x\n".utf8))
        try handle.close()

        let second = try FileTailer.read(path: path, offset: first.newOffset, priorInode: first.inode)
        XCTAssertTrue(second.didReset)
        XCTAssertEqual(second.lines, ["x"])
        XCTAssertEqual(second.newOffset, 2)
    }

    func testInodeChangeResetsToZero() throws {
        try write("old1\nold2\n")
        let first = try FileTailer.read(path: path, offset: 0, priorInode: 0)
        XCTAssertEqual(first.lines, ["old1", "old2"])

        // Replace the file with a fresh inode (delete + recreate) even though its size exceeds the
        // old offset, so only the inode check can catch the rotation.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        try write("new1\nnew2\nnew3\nnew4\n")

        let second = try FileTailer.read(path: path, offset: first.newOffset, priorInode: first.inode)
        XCTAssertTrue(second.didReset)
        XCTAssertEqual(second.lines, ["new1", "new2", "new3", "new4"])
        XCTAssertNotEqual(second.inode, first.inode)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try FileTailer.read(path: dir.appendingPathComponent("nope.jsonl").path, offset: 0, priorInode: 0))
    }
}
