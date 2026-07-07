import SwiftUI
import AppKit
import ByteLifeCore

/// Identifier for the Receipt scene, shared by the `WindowGroup` declaration and the toolbars that open it.
enum ReceiptWindow {
    static let id = "receipt"
}

/// The single hand-off between a Share click on a panel surface and the Receipt window that fulfils it.
/// A Share click records the day here before opening the window; the window reads it once it is front and
/// key and presents the sharing picker, then clears it. A shared singleton because the click site and the
/// window are different scenes with no direct binding between them.
@MainActor
final class ReceiptWindowCoordinator: ObservableObject {
    static let shared = ReceiptWindowCoordinator()
    /// The accounting day whose Receipt window should auto-present the sharing picker on becoming key, or
    /// nil when no share is pending.
    @Published var pendingShareDay: Int64?
    private init() {}
}

/// A real, titled window showing one day's stored receipt on the chassis, with an inline Share / Save
/// toolbar. This window is the stable host the sharing picker needs: unlike the menubar panel, it stays
/// alive when a compose target (Messages, Mail) activates, so the receipt image actually reaches the
/// conversation. It is opened by value (the day epoch) from either the panel or the Back Office, and it
/// reuses the exact eager-render / retained-picker path (`ReceiptSharePresenter`) that already works.
struct ReceiptWindowView: View {
    let dayEpoch: Int64
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var coordinator = ReceiptWindowCoordinator.shared
    /// Owns the live anchor view and the retained picker. The window's Share button and the auto-present
    /// on open both drive this one presenter, so the picker always anchors to the window's own button.
    @StateObject private var presenter = ReceiptSharePresenter()

    /// The stored receipt for this day, read from the shared store. A day only ever reaches this window
    /// once posted, so the receipt is expected to exist; the empty state below is purely defensive.
    private var reconciliation: Reconciliation? {
        (try? AppCoordinator.shared.store.reconciliation(forDayEpoch: dayEpoch)) ?? nil
    }

    var body: some View {
        Group {
            if let receipt = reconciliation {
                content(receipt)
            } else {
                Text("No receipt on file for this day.")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(LatticePalette.dim(scheme))
                    .padding(40)
            }
        }
        .background(LatticePalette.chassis(scheme))
        .foregroundStyle(LatticePalette.dial(scheme))
        .navigationTitle("Receipt · \(DayLabel.full(dayEpoch: dayEpoch))")
    }

    private func content(_ receipt: Reconciliation) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("RECEIPT")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LatticePalette.dial(scheme))
                Spacer()
                Button {
                    presenter.share(receipt)
                } label: {
                    Text("Share").font(.system(.caption, design: .monospaced))
                }
                .background(ShareAnchor(presenter: presenter))
                ReceiptSaveMenu(reconciliation: receipt)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(LatticePalette.hairline(scheme)).frame(height: 1)

            ScrollView(.vertical) {
                ReceiptStripView(reconciliation: receipt, fontSize: 12)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 380)
        .onAppear { autoShareIfPending(receipt) }
        .onChange(of: coordinator.pendingShareDay) { _, _ in autoShareIfPending(receipt) }
    }

    /// If this window was opened by a Share click for this very day, present the sharing picker once. The
    /// pending flag is consumed immediately so the fire happens exactly once, whether it is the fresh
    /// window's `onAppear` (flag set before the view existed) or an already-open window's `onChange` (flag
    /// set while the view was live). The async hop yields one runloop turn so the window has finished
    /// coming to front and the anchor view is laid out inside a key window before the picker anchors to it.
    private func autoShareIfPending(_ receipt: Reconciliation) {
        guard coordinator.pendingShareDay == dayEpoch else { return }
        coordinator.pendingShareDay = nil
        DispatchQueue.main.async {
            presenter.share(receipt)
        }
    }
}
