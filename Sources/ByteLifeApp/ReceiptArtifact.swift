import Foundation
import ByteLifeCore

/// One renderable receipt for the receipt surfaces: a past day's stored, sealed reconciliation, or the
/// open day's provisional compose. The strip, the exporter, and the toolbars all draw from this shape,
/// so a provisional receipt — which has no seal by design — can never grow a hash footer or a barcode
/// by accident on any surface.
struct ReceiptArtifact {
    let dayEpoch: Int64
    /// The receipt tape, verbatim: the stored text for a sealed day, the live compose for the open day.
    let text: String
    /// The content hash that seals a closed record; nil for a provisional receipt.
    let contentHash: String?

    init(sealed reconciliation: Reconciliation) {
        dayEpoch = reconciliation.dayEpoch
        text = reconciliation.receiptText
        contentHash = reconciliation.contentHash
    }

    init(provisional text: String, dayEpoch: Int64) {
        self.dayEpoch = dayEpoch
        self.text = text
        contentHash = nil
    }

    var isProvisional: Bool { contentHash == nil }
}

extension AppCoordinator {
    /// The receipt to render for `dayEpoch`: the stored sealed artifact when the day has posted,
    /// otherwise — for the current accounting day only — a provisional receipt composed live from the
    /// day's figures as of `asOf`. Nil for an unposted past day (the auto-closer has not reached it
    /// yet) or when the provisional compose hit a storage error; the surface then shows its defensive
    /// empty state and a later reload retries.
    func receiptArtifact(dayEpoch: Int64, asOf: Date = Date()) -> ReceiptArtifact? {
        if let stored = (try? store.reconciliation(forDayEpoch: dayEpoch)) ?? nil {
            return ReceiptArtifact(sealed: stored)
        }
        guard dayEpoch == DayBucket.dayEpoch(for: asOf),
              let text = try? reconciler.provisionalReceipt(
                  dayEpoch: dayEpoch, machineName: machineName, asOf: asOf
              )
        else { return nil }
        return ReceiptArtifact(provisional: text, dayEpoch: dayEpoch)
    }
}
