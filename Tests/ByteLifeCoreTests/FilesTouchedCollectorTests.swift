import XCTest
import CoreServices
@testable import ByteLifeCore

/// Covers the pure exclusion/counting filter, the FSEvents flag mapping, and the collector's `ingest`
/// path. The real FSEvents stream needs live filesystem activity and is not exercised here.
final class FilesTouchedCollectorTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private var timestamp: Date!
    private var dayEpoch: Int64!
    private let home = "/Users/tester"

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
        timestamp = fixedTimestamp()
        dayEpoch = DayBucket.dayEpoch(for: timestamp)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func total() throws -> Int64 {
        try store.totals(forDayEpoch: dayEpoch)[.filesTouched] ?? 0
    }

    func testFilterCountsCreateModifyRenameAndDropsExclusionsAndOther() {
        let exclusions = FilesTouchedFilter.defaultExclusions(home: home)
        let events = [
            FileTouchEvent(path: "\(home)/Documents/report.txt", kind: .created),   // counted
            FileTouchEvent(path: "\(home)/src/main.swift", kind: .modified),         // counted
            FileTouchEvent(path: "\(home)/src/old.swift", kind: .renamed),           // counted
            FileTouchEvent(path: "\(home)/Documents/report.txt", kind: .other),      // dropped: not a touch
            FileTouchEvent(path: "\(home)/Library/Caches/x", kind: .modified),       // dropped: ~/Library
            FileTouchEvent(path: "\(home)/proj/node_modules/a.js", kind: .created),  // dropped: node_modules
            FileTouchEvent(path: "\(home)/proj/.git/index", kind: .modified),        // dropped: .git internals
            FileTouchEvent(path: "\(home)/proj/.build/x.o", kind: .created),         // dropped: .build
            FileTouchEvent(path: "\(home)/proj/Caches/tmp", kind: .modified),        // dropped: a Caches dir
        ]
        XCTAssertEqual(FilesTouchedFilter.count(events, exclusions: exclusions), 3)
    }

    func testFSEventFlagMapping() {
        func kind(_ flag: Int) -> FileTouchKind {
            FilesTouchedCollector.kind(from: FSEventStreamEventFlags(flag))
        }
        XCTAssertEqual(kind(kFSEventStreamEventFlagItemCreated), .created)
        XCTAssertEqual(kind(kFSEventStreamEventFlagItemRenamed), .renamed)
        XCTAssertEqual(kind(kFSEventStreamEventFlagItemModified), .modified)
        XCTAssertEqual(kind(kFSEventStreamEventFlagItemRemoved), .other)
        // Create wins when several bits are set, but either way it still counts as one touch.
        XCTAssertEqual(
            kind(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified), .created
        )
    }

    func testIngestBooksCountedTouchesAsAdditiveDeltas() throws {
        let collector = FilesTouchedCollector(store: store, home: home)
        collector.ingest([
            FileTouchEvent(path: "\(home)/a.txt", kind: .created),
            FileTouchEvent(path: "\(home)/b.txt", kind: .modified),
            FileTouchEvent(path: "\(home)/Library/pref", kind: .modified),   // excluded
        ], now: timestamp)
        XCTAssertEqual(try total(), 2)

        // A second batch adds to the first (additive).
        collector.ingest([FileTouchEvent(path: "\(home)/c.txt", kind: .renamed)], now: timestamp)
        XCTAssertEqual(try total(), 3)

        // An all-excluded batch writes nothing.
        collector.ingest([FileTouchEvent(path: "\(home)/Library/x", kind: .created)], now: timestamp)
        XCTAssertEqual(try total(), 3)
    }

    func testAppDataDirExclusionIsHonoredExplicitly() {
        let appDataDir = "/Users/tester/Library/Application Support/ByteLife"
        let collector = FilesTouchedCollector(store: store, home: home, appDataDir: appDataDir)
        collector.ingest([FileTouchEvent(path: "\(appDataDir)/bytelife.sqlite", kind: .modified)], now: timestamp)
        // The app's own store writes are never counted (covered by ~/Library and the explicit entry).
        XCTAssertEqual((try? store.totals(forDayEpoch: dayEpoch)[.filesTouched]) ?? 0, 0)
    }
}
