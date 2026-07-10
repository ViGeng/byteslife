import XCTest
@testable import ByteLifeCore

final class ReconcilerTests: XCTestCase {
    private func availability(all state: Availability) -> [CollectorAvailability] {
        MetricFamily.allCases.map {
            CollectorAvailability(id: $0.rawValue, family: $0, availability: state)
        }
    }

    private func dayEpoch(_ date: Date) -> Int64 { DayBucket.dayEpoch(for: date) }

    func testReconcileStoresAHashStampedReceipt() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let today = fixedTimestamp(minute: 30)
        try store.record([
            Sample(kind: .aiInputTokens, value: 1_000, timestamp: today),
            Sample(kind: .aiOutputTokens, value: 4_000, timestamp: today),
            Sample(kind: .networkBytesIn, value: 2_000, timestamp: today),
        ])

        let reconciler = Reconciler(store: store)
        let result = try reconciler.reconcile(
            dayEpoch: dayEpoch(today),
            availability: availability(all: .running),
            machineName: "test-mac"
        )

        let receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.stamp, "BALANCED")
        XCTAssertEqual(receipt.contentHash.count, 16)
        XCTAssertTrue(receipt.receiptText.contains("test-mac"))

        // The stored row round-trips identically.
        let stored = try XCTUnwrap(store.reconciliation(forDayEpoch: dayEpoch(today)))
        XCTAssertEqual(stored, receipt)
    }

    func testADroppedSourceFlagsTheShortAccount() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let today = fixedTimestamp(minute: 10)
        try store.record([Sample(kind: .networkBytesIn, value: 500, timestamp: today)])

        var avail = availability(all: .running)
        avail = avail.map { $0.family == .disk ? CollectorAvailability(id: $0.id, family: .disk, availability: .sourceMissing) : $0 }

        let receipt = try XCTUnwrap(Reconciler(store: store).reconcile(
            dayEpoch: dayEpoch(today), availability: avail, machineName: "m"
        ))
        XCTAssertEqual(receipt.stamp, "FLAGGED")
        XCTAssertTrue(receipt.receiptText.contains("Storage Account"))
    }

    func testClosesAPastDayLeavingTodayOpen() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Data on a day three days back and on today, so the two land in distinct accounting periods.
        let today = fixedTimestamp(minute: 30)
        let past = today.addingTimeInterval(-3 * 86_400)
        try store.record([
            Sample(kind: .networkBytesIn, value: 3_000, timestamp: past),
            Sample(kind: .networkBytesOut, value: 1_000, timestamp: past),
            Sample(kind: .inputKeystrokes, value: 100, timestamp: today),
        ])

        let reconciler = Reconciler(store: store)
        let pastEpoch = dayEpoch(past)
        let todayEpoch = dayEpoch(today)
        XCTAssertNotEqual(pastEpoch, todayEpoch)

        // Closing the past day composes and posts its receipt through the full path.
        let receipt = try XCTUnwrap(reconciler.reconcile(
            dayEpoch: pastEpoch, availability: availability(all: .running), machineName: "m"))
        XCTAssertEqual(receipt.stamp, "BALANCED")
        XCTAssertTrue(receipt.receiptText.contains("TRAFFIC ACCOUNT"))
        XCTAssertTrue(receipt.receiptText.contains("Bytes Remitted"))

        // The past day is now posted; today stays open.
        XCTAssertNotNil(try store.reconciliation(forDayEpoch: pastEpoch))
        XCTAssertNil(try store.reconciliation(forDayEpoch: todayEpoch))
        XCTAssertEqual(try store.reconciledDayEpochs(), [pastEpoch])

        // Exactly-once holds through the full compose-and-post path: a second close is a no-op.
        XCTAssertNil(try reconciler.reconcile(
            dayEpoch: pastEpoch, availability: availability(all: .running), machineName: "m"))
        XCTAssertEqual(try store.reconciledDayEpochs().count, 1)
    }

    /// An arrears close (how the app posts any past day) stores the POSTED IN ARREARS stamp and its
    /// disclosure, regardless of what the live collectors report at the moment of closing.
    func testArrearsCloseStoresArrearsStamp() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let past = fixedTimestamp(minute: 30).addingTimeInterval(-2 * 86_400)
        try store.record([Sample(kind: .diskBytesWritten, value: 9_000, timestamp: past)])

        let receipt = try XCTUnwrap(Reconciler(store: store).reconcile(
            dayEpoch: dayEpoch(past),
            availability: availability(all: .needsPermission),
            machineName: "m",
            closedInArrears: true
        ))
        XCTAssertEqual(receipt.stamp, "POSTED IN ARREARS")
        XCTAssertTrue(receipt.receiptText.contains("* POSTED IN ARREARS *"))
        XCTAssertFalse(receipt.receiptText.contains("FLAGGED"))
        XCTAssertEqual(try store.reconciliation(forDayEpoch: dayEpoch(past))?.stamp, "POSTED IN ARREARS")
    }

    /// The full close path books the iteration-10 lines: the notional cost with its list-price framing
    /// (a day with no model rows values honestly at $0.00) and the Composite line, which reads its
    /// collecting state while the baseline is short instead of faking a number.
    func testReconcileBooksCostAndCompositeLines() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let today = fixedTimestamp(minute: 30)
        try store.record([Sample(kind: .networkBytesIn, value: 2_000, timestamp: today)])

        let receipt = try XCTUnwrap(Reconciler(store: store).reconcile(
            dayEpoch: dayEpoch(today), availability: availability(all: .running), machineName: "m"))
        XCTAssertTrue(receipt.receiptText.contains("Notional cost (list)"))
        XCTAssertTrue(receipt.receiptText.contains("$0.00"))
        XCTAssertTrue(receipt.receiptText.contains("At list prices as of"))
        XCTAssertTrue(receipt.receiptText.contains("Composite vs 28-day median: collecting"))
    }

    func testADayClosesExactlyOnce() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let today = fixedTimestamp(minute: 5)
        try store.record([Sample(kind: .inputKeystrokes, value: 42, timestamp: today)])
        let reconciler = Reconciler(store: store)

        XCTAssertNotNil(try reconciler.reconcile(
            dayEpoch: dayEpoch(today), availability: availability(all: .running), machineName: "m"))
        // Second attempt is a no-op.
        XCTAssertNil(try reconciler.reconcile(
            dayEpoch: dayEpoch(today), availability: availability(all: .running), machineName: "m"))
        XCTAssertEqual(try store.reconciledDayEpochs().count, 1)
    }
}
