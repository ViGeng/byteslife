import Foundation

/// Closes an accounting day: it gathers the day's totals, asks the margin engine for the single dry
/// note, composes the immutable receipt with the collector states at close, and posts it to the store
/// exactly once. This is pure orchestration over `ReceiptComposer`, `MarginNotes`, and `SampleStore`;
/// the composition itself is deterministic and separately tested. It lives in the core so `swift test`
/// covers the close path end to end.
public struct Reconciler {
    private let store: SampleStore

    /// How many trailing recorded days the margin engine compares the closing day against.
    public static let trailingWindow = 7

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

        let totals = try store.totals(forDayEpoch: dayEpoch)
        let trailing = try trailingTotals(before: dayEpoch)
        let comment = MarginNotes.comment(today: totals, trailing: trailing)
        // The accessory figures the AUXILIARY section books: distinct hosts and the day's top app come
        // from their own tables (the samples dictionary cannot carry the per-app or per-host dimension).
        let distinctHosts = (try? store.distinctHosts(dayEpoch: dayEpoch)) ?? 0
        let topApp = (try? store.topFocus(dayEpoch: dayEpoch, limit: 1))?.first.map {
            (name: AppShortName.short(bundleID: $0.bundleId), seconds: $0.seconds)
        }
        let receipt = ReceiptComposer.compose(
            dayEpoch: dayEpoch,
            totals: totals,
            availability: availability,
            machineName: machineName,
            marginComment: comment,
            calendar: calendar,
            closedInArrears: closedInArrears,
            auxDistinctHosts: distinctHosts,
            auxTopApp: topApp
        )
        let reconciliation = Reconciliation(
            dayEpoch: dayEpoch,
            closedAt: Int64(now.timeIntervalSince1970.rounded(.down)),
            receiptText: receipt.text,
            contentHash: receipt.contentHash,
            stamp: receipt.stamp.storageValue,
            comment: comment
        )
        let inserted = try store.insertReconciliation(reconciliation)
        // A race that lost the insert (another close beat us) reports as already closed.
        return inserted ? reconciliation : nil
    }

    /// The recorded days immediately before `dayEpoch`, newest first up to `trailingWindow`, as totals
    /// dictionaries in the order the margin engine expects.
    private func trailingTotals(before dayEpoch: Int64) throws -> [[MetricKind: Int64]] {
        let days = try store.dayEpochsWithData()
            .filter { $0 < dayEpoch }
            .prefix(Reconciler.trailingWindow)
        guard !days.isEmpty else { return [] }
        let byDay = try store.totals(forDayEpochs: Array(days))
        return days.map { byDay[$0] ?? [:] }
    }
}
