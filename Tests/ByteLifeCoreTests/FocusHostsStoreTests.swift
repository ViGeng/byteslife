import XCTest
@testable import ByteLifeCore

/// Covers the v3 store APIs: the per-app `focus` ledger (UPSERT accumulate, ranked reads) and the
/// per-day `hosts_seen` dedup set (distinct-count semantics).
final class FocusHostsStoreTests: XCTestCase {
    private var store: SampleStore!
    private var directory: URL!
    private let day: Int64 = 1_000_000

    override func setUpWithError() throws {
        (store, directory) = try TempStore.make()
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordFocusAccumulatesAndTopFocusRanks() throws {
        try store.recordFocus(dayEpoch: day, bundleId: "com.a", seconds: 30)
        try store.recordFocus(dayEpoch: day, bundleId: "com.a", seconds: 20)   // accumulates to 50
        try store.recordFocus(dayEpoch: day, bundleId: "com.b", seconds: 90)
        try store.recordFocus(dayEpoch: day, bundleId: "com.c", seconds: 5)
        // A non-positive write is a no-op.
        try store.recordFocus(dayEpoch: day, bundleId: "com.c", seconds: 0)

        let top = try store.topFocus(dayEpoch: day, limit: 2)
        XCTAssertEqual(top.map(\.bundleId), ["com.b", "com.a"])
        XCTAssertEqual(top.map(\.seconds), [90, 50])

        // The full ranking, longest first.
        let all = try store.topFocus(dayEpoch: day, limit: 10)
        XCTAssertEqual(all.map(\.bundleId), ["com.b", "com.a", "com.c"])
        XCTAssertEqual(all.first(where: { $0.bundleId == "com.a" })?.seconds, 50)

        // A different day sees none of it.
        XCTAssertTrue(try store.topFocus(dayEpoch: day + 86_400, limit: 5).isEmpty)
        // A zero limit returns nothing.
        XCTAssertTrue(try store.topFocus(dayEpoch: day, limit: 0).isEmpty)
    }

    func testFocusForDayEpochsGroupsPerDay() throws {
        let other = day + 86_400
        try store.recordFocus(dayEpoch: day, bundleId: "com.a", seconds: 30)
        try store.recordFocus(dayEpoch: day, bundleId: "com.b", seconds: 90)
        try store.recordFocus(dayEpoch: other, bundleId: "com.a", seconds: 15)

        let byDay = try store.focus(forDayEpochs: [day, other, day + 999_999])
        XCTAssertEqual(byDay[day], ["com.a": 30, "com.b": 90])
        XCTAssertEqual(byDay[other], ["com.a": 15])
        // A day with no rows is absent, and an empty request returns empty.
        XCTAssertNil(byDay[day + 999_999])
        XCTAssertTrue(try store.focus(forDayEpochs: []).isEmpty)
    }

    func testDistinctHostsForDayEpochsGroupsPerDay() throws {
        let other = day + 86_400
        XCTAssertTrue(try store.markHostSeen(dayEpoch: day, hash: "h1"))
        XCTAssertTrue(try store.markHostSeen(dayEpoch: day, hash: "h2"))
        XCTAssertTrue(try store.markHostSeen(dayEpoch: other, hash: "h1"))

        let byDay = try store.distinctHosts(forDayEpochs: [day, other, day + 999_999])
        XCTAssertEqual(byDay[day], 2)
        XCTAssertEqual(byDay[other], 1)
        XCTAssertNil(byDay[day + 999_999])
        XCTAssertTrue(try store.distinctHosts(forDayEpochs: []).isEmpty)
    }

    func testMarkHostSeenDedupsPerDayAndCounts() throws {
        XCTAssertTrue(try store.markHostSeen(dayEpoch: day, hash: "h1"))
        XCTAssertFalse(try store.markHostSeen(dayEpoch: day, hash: "h1"))  // same day, already seen
        XCTAssertTrue(try store.markHostSeen(dayEpoch: day, hash: "h2"))
        XCTAssertEqual(try store.distinctHosts(dayEpoch: day), 2)

        // The same host on another day is a fresh distinct sighting there.
        let other = day + 86_400
        XCTAssertTrue(try store.markHostSeen(dayEpoch: other, hash: "h1"))
        XCTAssertEqual(try store.distinctHosts(dayEpoch: other), 1)
        // The first day is unchanged.
        XCTAssertEqual(try store.distinctHosts(dayEpoch: day), 2)
        // A day with no sightings counts zero.
        XCTAssertEqual(try store.distinctHosts(dayEpoch: day + 999_999), 0)
    }
}
