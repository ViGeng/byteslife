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

    // MARK: - The auto-closer

    /// Local midnight of the current day, the rollover moment the grace-window tests pivot on.
    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    /// A store holding one sample early on the day `daysBack` before today, returned with that
    /// sample's day epoch.
    private func storeWithData(daysBack: Int) throws -> (SampleStore, URL, Int64) {
        let (store, dir) = try TempStore.make()
        let dayStart = Calendar.current.date(byAdding: .day, value: -daysBack, to: todayStart)!
        try store.record([
            Sample(kind: .networkBytesIn, value: 1_000, timestamp: dayStart.addingTimeInterval(600))
        ])
        return (store, dir, dayEpoch(dayStart))
    }

    /// Yesterday, swept 5 minutes after its own midnight by an app awake through the rollover,
    /// stamps from the live snapshot instead of posting in arrears.
    func testAutoCloseInsideGraceStampsFromLiveSnapshot() throws {
        let (store, dir, yesterday) = try storeWithData(daysBack: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let posted = try Reconciler(store: store).closeOverdueDays(
            availability: availability(all: .running),
            machineName: "m",
            awakeSince: todayStart.addingTimeInterval(-3_600),
            now: todayStart.addingTimeInterval(300)
        )
        XCTAssertEqual(posted.map(\.dayEpoch), [yesterday])
        XCTAssertEqual(posted.first?.stamp, "BALANCED")
        XCTAssertEqual(try store.reconciliation(forDayEpoch: yesterday)?.stamp, "BALANCED")
    }

    /// Inside the grace window the live snapshot is an honest witness, so a short collector flags the
    /// just-ended day exactly as a manual live close would have.
    func testAutoCloseInsideGraceFlagsShortAccounts() throws {
        let (store, dir, yesterday) = try storeWithData(daysBack: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        var avail = availability(all: .running)
        avail = avail.map {
            $0.family == .disk
                ? CollectorAvailability(id: $0.id, family: .disk, availability: .sourceMissing)
                : $0
        }
        let posted = try Reconciler(store: store).closeOverdueDays(
            availability: avail,
            machineName: "m",
            awakeSince: todayStart.addingTimeInterval(-3_600),
            now: todayStart.addingTimeInterval(300)
        )
        XCTAssertEqual(posted.first?.stamp, "FLAGGED")
        XCTAssertEqual(try store.reconciliation(forDayEpoch: yesterday)?.stamp, "FLAGGED")
    }

    /// A sweep past the 10-minute window posts yesterday in arrears even though the app was awake at
    /// the rollover: the snapshot is no longer an honest witness of the day that ended.
    func testAutoCloseAfterGraceWindowPostsInArrears() throws {
        let (store, dir, yesterday) = try storeWithData(daysBack: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let posted = try Reconciler(store: store).closeOverdueDays(
            availability: availability(all: .running),
            machineName: "m",
            awakeSince: todayStart.addingTimeInterval(-3_600),
            now: todayStart.addingTimeInterval(Reconciler.graceWindow + 60)
        )
        XCTAssertEqual(posted.first?.stamp, "POSTED IN ARREARS")
        XCTAssertEqual(
            try store.reconciliation(forDayEpoch: yesterday)?.stamp, "POSTED IN ARREARS")
    }

    /// An app launched after midnight did not witness the rollover, so even a sweep inside the
    /// 10-minute window posts yesterday in arrears.
    func testAutoCloseAfterLateLaunchPostsInArrears() throws {
        let (store, dir, yesterday) = try storeWithData(daysBack: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let posted = try Reconciler(store: store).closeOverdueDays(
            availability: availability(all: .running),
            machineName: "m",
            awakeSince: todayStart.addingTimeInterval(120),
            now: todayStart.addingTimeInterval(300)
        )
        XCTAssertEqual(posted.first?.stamp, "POSTED IN ARREARS")
        XCTAssertEqual(
            try store.reconciliation(forDayEpoch: yesterday)?.stamp, "POSTED IN ARREARS")
    }

    /// While the machine sleeps the app layer parks the witness at `.distantFuture`, so a sweep that
    /// races the wake notification onto the run loop posts a slept-through midnight in arrears
    /// instead of live-stamping it from a snapshot that never saw the rollover.
    func testAutoCloseWithAsleepWitnessSentinelPostsInArrears() throws {
        let (store, dir, yesterday) = try storeWithData(daysBack: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let posted = try Reconciler(store: store).closeOverdueDays(
            availability: availability(all: .running),
            machineName: "m",
            awakeSince: .distantFuture,
            now: todayStart.addingTimeInterval(300)
        )
        XCTAssertEqual(posted.first?.stamp, "POSTED IN ARREARS")
        XCTAssertEqual(
            try store.reconciliation(forDayEpoch: yesterday)?.stamp, "POSTED IN ARREARS")
    }

    /// The first sweep over an upgraded store backfill-posts every historical unposted day in arrears,
    /// oldest first, and leaves the open day open.
    func testAutoCloseBackfillsHistoryChronologicallyInArrears() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let calendar = Calendar.current
        var pastEpochs: [Int64] = []
        for daysBack in [3, 2, 1] {
            let dayStart = calendar.date(byAdding: .day, value: -daysBack, to: todayStart)!
            try store.record([
                Sample(kind: .inputKeystrokes, value: 10, timestamp: dayStart.addingTimeInterval(600))
            ])
            pastEpochs.append(dayEpoch(dayStart))
        }
        try store.record([Sample(kind: .inputKeystrokes, value: 5, timestamp: fixedTimestamp())])

        let now = todayStart.addingTimeInterval(12 * 3_600)
        let posted = try Reconciler(store: store).closeOverdueDays(
            availability: availability(all: .running),
            machineName: "m",
            awakeSince: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertEqual(posted.map(\.dayEpoch), pastEpochs.sorted())
        XCTAssertTrue(posted.allSatisfy { $0.stamp == "POSTED IN ARREARS" })
        XCTAssertNil(try store.reconciliation(forDayEpoch: dayEpoch(fixedTimestamp())))
    }

    /// Repeated ticks and a re-launch sweep are no-ops after the first close: exactly-once holds and
    /// the stored receipt does not change.
    func testAutoCloseIsIdempotentAcrossRepeatedTicks() throws {
        let (store, dir, yesterday) = try storeWithData(daysBack: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        let reconciler = Reconciler(store: store)
        let sweep = { (secondsAfterMidnight: TimeInterval) in
            try reconciler.closeOverdueDays(
                availability: self.availability(all: .running),
                machineName: "m",
                awakeSince: self.todayStart.addingTimeInterval(-3_600),
                now: self.todayStart.addingTimeInterval(secondsAfterMidnight)
            )
        }
        let first = try sweep(300)
        XCTAssertEqual(first.count, 1)
        let stored = try XCTUnwrap(store.reconciliation(forDayEpoch: yesterday))

        // A tick 30 seconds later, another inside the window, and one far outside it all post nothing.
        XCTAssertTrue(try sweep(330).isEmpty)
        XCTAssertTrue(try sweep(590).isEmpty)
        XCTAssertTrue(try sweep(7_200).isEmpty)
        XCTAssertEqual(try store.reconciledDayEpochs(), [yesterday])
        XCTAssertEqual(try store.reconciliation(forDayEpoch: yesterday), stored)
    }

    // MARK: - The provisional receipt

    /// The open day's provisional receipt composes live from the store, carries the DAY OPEN header,
    /// prints no content hash, and writes nothing back.
    func testProvisionalReceiptComposesLiveWithoutStoring() throws {
        let (store, dir) = try TempStore.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let today = fixedTimestamp(minute: 30)
        try store.record([
            Sample(kind: .aiInputTokens, value: 1_000, timestamp: today),
            Sample(kind: .networkBytesIn, value: 2_000, timestamp: today),
        ])

        let text = try Reconciler(store: store).provisionalReceipt(
            dayEpoch: dayEpoch(today), machineName: "test-mac", asOf: today)
        XCTAssertTrue(text.contains("DAY OPEN — FIGURES AS OF 00:30"))
        XCTAssertTrue(text.contains("test-mac"))
        XCTAssertTrue(text.contains("Notional cost (list)"))
        XCTAssertFalse(text.contains("Content hash"))
        XCTAssertNil(try store.reconciliation(forDayEpoch: dayEpoch(today)))
        XCTAssertEqual(try store.reconciledDayEpochs(), [])
    }
}
