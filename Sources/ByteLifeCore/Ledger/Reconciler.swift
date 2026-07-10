import Foundation

/// Closes an accounting day: it gathers the day's totals, asks the margin engine for the single dry
/// note, composes the immutable receipt with the collector states at close, and posts it to the store
/// exactly once. `closeOverdueDays` sweeps every unposted past day on the app's slow tick (the
/// self-keeping books), and `provisionalReceipt` composes the open day's unsealed receipt live. This
/// is pure orchestration over `ReceiptComposer`, `MarginNotes`, and `SampleStore`; the composition
/// itself is deterministic and separately tested. It lives in the core so `swift test` covers the
/// close path end to end.
public struct Reconciler {
    private let store: SampleStore

    /// How many trailing recorded days the margin engine compares the closing day against.
    public static let trailingWindow = 7

    /// How long after a day's own midnight its live-witness close stays honest: within this window an
    /// app that was awake through the rollover may still stamp the just-ended day from the live
    /// collector snapshot. Beyond it, or after a launch that missed the rollover, the day posts in
    /// arrears.
    public static let graceWindow: TimeInterval = 10 * 60

    public init(store: SampleStore) {
        self.store = store
    }

    /// Closes `dayEpoch`, returning the stored reconciliation on success or `nil` when the day was
    /// already closed (a day posts exactly once). Throws only on a storage error. Pass
    /// `closedInArrears: true` when closing a past day, so the receipt discloses the late posting
    /// instead of stamping it from today's collector states.
    @discardableResult
    public func reconcile(
        dayEpoch: Int64,
        availability: [CollectorAvailability],
        machineName: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        closedInArrears: Bool = false
    ) throws -> Reconciliation? {
        // A day closes exactly once; a second attempt is a no-op rather than an overwrite.
        if try store.reconciliation(forDayEpoch: dayEpoch) != nil { return nil }

        let figures = try figures(forDayEpoch: dayEpoch)
        let receipt = ReceiptComposer.compose(
            dayEpoch: dayEpoch,
            totals: figures.totals,
            availability: availability,
            machineName: machineName,
            marginComment: figures.comment,
            calendar: calendar,
            closedInArrears: closedInArrears,
            auxDistinctHosts: figures.distinctHosts,
            auxTopApp: figures.topApp,
            aiCost: figures.aiCost,
            composite: figures.composite
        )
        let reconciliation = Reconciliation(
            dayEpoch: dayEpoch,
            closedAt: Int64(now.timeIntervalSince1970.rounded(.down)),
            receiptText: receipt.text,
            contentHash: receipt.contentHash,
            stamp: receipt.stamp.storageValue,
            comment: figures.comment
        )
        let inserted = try store.insertReconciliation(reconciliation)
        // A race that lost the insert (another close beat us) reports as already closed.
        return inserted ? reconciliation : nil
    }

    /// Closes every recorded day older than `now`'s accounting day that has no reconciliation row,
    /// oldest first, returning the newly posted reconciliations. A day still inside its grace window
    /// (its own midnight passed no more than `graceWindow` ago, and the app has been awake since
    /// before that midnight, so the live snapshot still honestly witnesses it) stamps from
    /// `availability`; every other day posts in arrears. Safe to call on every tick and from
    /// concurrent launches: posted days are skipped, and the store's INSERT OR IGNORE stays the one
    /// exactly-once guard. The first sweep over an upgraded store backfill-posts all history the same
    /// way, since no historical day can still be in grace.
    @discardableResult
    public func closeOverdueDays(
        availability: [CollectorAvailability],
        machineName: String,
        awakeSince: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [Reconciliation] {
        let currentDay = DayBucket.dayEpoch(for: now, calendar: calendar)
        let posted = Set(try store.reconciledDayEpochs())
        let overdue = try store.dayEpochsWithData()
            .filter { $0 < currentDay && !posted.contains($0) }
            .sorted()
        var newlyPosted: [Reconciliation] = []
        for day in overdue {
            // The rollover moment that ended `day` is the following day's local midnight.
            let dayEnd = calendar.date(
                byAdding: .day, value: 1, to: Date(timeIntervalSince1970: TimeInterval(day))
            ) ?? Date(timeIntervalSince1970: TimeInterval(day) + 86_400)
            let inGrace = now.timeIntervalSince(dayEnd) <= Self.graceWindow && awakeSince <= dayEnd
            if let reconciliation = try reconcile(
                dayEpoch: day,
                availability: availability,
                machineName: machineName,
                now: now,
                calendar: calendar,
                closedInArrears: !inGrace
            ) {
                newlyPosted.append(reconciliation)
            }
        }
        return newlyPosted
    }

    /// The OPEN day's receipt composed live from current figures: it carries the "DAY OPEN — FIGURES
    /// AS OF HH:MM" header where the stamp would sit, and no content hash and no barcode, because the
    /// hash is the seal of a closed record. Compose-only: nothing is written to the store.
    public func provisionalReceipt(
        dayEpoch: Int64,
        machineName: String,
        asOf: Date = Date(),
        calendar: Calendar = .current
    ) throws -> String {
        let figures = try figures(forDayEpoch: dayEpoch)
        return ReceiptComposer.composeProvisional(
            dayEpoch: dayEpoch,
            totals: figures.totals,
            machineName: machineName,
            marginComment: figures.comment,
            asOf: asOf,
            calendar: calendar,
            auxDistinctHosts: figures.distinctHosts,
            auxTopApp: figures.topApp,
            aiCost: figures.aiCost,
            composite: figures.composite
        )
    }

    /// The figures one day's receipt books, gathered identically for a sealed close and a provisional
    /// compose so the two surfaces can never disagree on the same store.
    private struct DayFigures {
        let totals: [MetricKind: Int64]
        let composite: Composite
        let comment: String
        let aiCost: AICostSummary
        let distinctHosts: Int
        let topApp: (name: String, seconds: Int64)?
    }

    private func figures(forDayEpoch dayEpoch: Int64) throws -> DayFigures {
        let totals = try store.totals(forDayEpoch: dayEpoch)
        // One trailing fetch serves both readers: the Composite baseline spans up to 28 recorded days,
        // and the margin engine reads the newest 7 of the same map.
        let (trailingDays, history) = try trailingHistory(before: dayEpoch)
        let composite = Composite.build(dayEpoch: dayEpoch, todayTotals: totals, history: history)
        let trailing = trailingDays.prefix(Reconciler.trailingWindow).map { history[$0] ?? [:] }
        let comment = MarginNotes.comment(today: totals, trailing: trailing, composite: composite)
        // The day's notional AI cost at bundled list prices, booked in the receipt's Token Account.
        // This read must throw like `totals` does: swallowing a storage error here would immortalize a
        // silently zeroed "Notional cost (list) $0.00" in the insert-once receipt. Aborting lets a later
        // close retry with the real rows. (An empty row set on a healthy store is a genuine $0.00 day.)
        let aiCost = PriceCard.bundled.cost(of: try store.aiModelTotals(dayEpoch: dayEpoch))
        // The accessory figures the AUXILIARY section books: distinct hosts and the day's top app come
        // from their own tables (the samples dictionary cannot carry the per-app or per-host dimension).
        let distinctHosts = (try? store.distinctHosts(dayEpoch: dayEpoch)) ?? 0
        let topApp = (try? store.topFocus(dayEpoch: dayEpoch, limit: 1))?.first.map {
            (name: AppShortName.short(bundleID: $0.bundleId), seconds: $0.seconds)
        }
        return DayFigures(
            totals: totals,
            composite: composite,
            comment: comment,
            aiCost: aiCost,
            distinctHosts: distinctHosts,
            topApp: topApp
        )
    }

    /// The recorded days immediately before `dayEpoch`, newest first up to the Composite's 28-day
    /// baseline window, with their totals map. The margin engine takes the newest `trailingWindow` days
    /// of the same fetch.
    private func trailingHistory(
        before dayEpoch: Int64
    ) throws -> (days: [Int64], history: [Int64: [MetricKind: Int64]]) {
        let days = Array(
            try store.dayEpochsWithData()
                .filter { $0 < dayEpoch }
                .prefix(Composite.baselineWindow)
        )
        guard !days.isEmpty else { return ([], [:]) }
        return (days, try store.totals(forDayEpochs: days))
    }
}
