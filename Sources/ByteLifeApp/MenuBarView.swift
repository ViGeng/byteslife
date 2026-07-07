import SwiftUI
import ByteLifeCore

/// The menubar app: a `.window`-style MenuBarExtra whose label is a glyph plus today's running balance,
/// and whose dropdown is the live Ledger day sheet. The view model is a StateObject so it lives for the
/// whole session and drives the polling timer.
struct ByteLifeApplication: App {
    @StateObject private var viewModel = DashboardViewModel(coordinator: .shared)

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            // Glyph plus today's posted byte volume, kept compact for the menubar.
            Image(systemName: "book.closed")
            Text(viewModel.menubarBalance)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        // The General Ledger opens as its own document-style window. It is a stub in this iteration.
        Window("General Ledger", id: GeneralLedgerWindow.id) {
            GeneralLedgerView()
        }
    }
}

/// The menubar panel: the live Meter Bridge instrument on a fixed dark faceplate, with the Reconcile
/// control and footer beneath it. The bridge reads live rates and history bars; the footer keeps the
/// record layer (Reconcile, the POSTED stamp, the receipt, the General Ledger) exactly as it behaves.
/// The panel is always dark regardless of the system appearance, the way real hardware has a fixed face.
struct MenuBarView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.openWindow) private var openWindow
    /// When true, the panel shows the stored receipt strip in place of the meter. Set on posting and by
    /// the posted-state "View receipt" control; cleared by the strip's Done button.
    @State private var showingReceipt = false

    private var ink: Color { LatticePalette.dial }

    var body: some View {
        Group {
            if showingReceipt, let receipt = viewModel.todaysReceipt {
                receiptPanel(receipt)
            } else {
                meterPanel
            }
        }
        .frame(width: 360, alignment: .leading)
        .background(LatticePalette.chassis)
        .foregroundStyle(ink)
        // The panel polls fast and animates while open, slow and label-only while closed.
        .onAppear { viewModel.panelDidAppear() }
        .onDisappear { viewModel.panelDidDisappear() }
    }

    private var meterPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeterBridgeView(viewModel: viewModel)
            reconcileBar
            Rectangle().fill(LatticePalette.hairline).frame(height: 1)
            footer
        }
    }

    // MARK: - Receipt strip

    /// The stored receipt shown inside the panel after a close, with a Done control back to the day
    /// sheet. Motion stays minimal and mechanical: the strip simply appears, no flourish.
    private func receiptPanel(_ receipt: Reconciliation) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("RECEIPT")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LatticePalette.dial)
                Spacer()
                Button("Done") { withAnimation(.easeOut(duration: 0.15)) { showingReceipt = false } }
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(LatticePalette.hairline).frame(height: 1)

            ScrollView(.vertical) {
                ReceiptStripView(reconciliation: receipt)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
        }
        .transition(.opacity)
    }

    // MARK: - Reconcile

    /// Brass is reserved for the balanced close and nothing else: a flagged day reads in oxblood and
    /// an arrears posting in plain ink, so gold always means resolution.
    private func stampColor(_ stamp: String) -> Color {
        switch stamp {
        case "BALANCED": return LedgerPalette.brass
        case "FLAGGED": return LedgerPalette.debit
        default: return ink
        }
    }

    private func stampIcon(_ stamp: String) -> String {
        switch stamp {
        case "BALANCED": return "checkmark.seal.fill"
        case "FLAGGED": return "flag.fill"
        default: return "clock.arrow.circlepath"
        }
    }

    @ViewBuilder
    private var reconcileBar: some View {
        HStack {
            if viewModel.daySheet.isPosted {
                let stamp = viewModel.daySheet.stamp ?? "POSTED"
                Label(stamp, systemImage: stampIcon(stamp))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(stampColor(stamp))
                Spacer()
                // The disabled POSTED state, alongside a control to reopen the immutable artifact.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showingReceipt = true }
                } label: {
                    Text("View receipt")
                        .font(.system(.caption2, design: .monospaced))
                }
                .disabled(viewModel.todaysReceipt == nil)
                Text("POSTED")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(stampColor(stamp))
            } else {
                Spacer()
                Button {
                    // Closing the books composes and posts the receipt, then presents the strip.
                    if viewModel.reconcileToday() {
                        withAnimation(.easeOut(duration: 0.15)) { showingReceipt = true }
                    }
                } label: {
                    Text("Reconcile")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { _ in viewModel.toggleLaunchAtLogin() }
                )) {
                    Text(viewModel.launchAtLoginAvailable ? "Launch at login" : "Launch at login (unavailable)")
                        .font(.system(.caption2, design: .monospaced))
                }
                .toggleStyle(.checkbox)
                .disabled(!viewModel.launchAtLoginAvailable)
                Spacer()
            }

            HStack {
                Button {
                    openWindow(id: GeneralLedgerWindow.id)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text("General Ledger…")
                        .font(.system(.caption2, design: .monospaced))
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.system(.caption2, design: .monospaced))
                    .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
