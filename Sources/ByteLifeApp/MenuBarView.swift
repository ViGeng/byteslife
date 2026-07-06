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

/// The Ledger day sheet: five account blocks with aligned debit and credit columns, a Reconcile control,
/// and a footer. The whole sheet shares one `Grid` so the debit and credit figures line up to the pixel
/// across every account, exactly as a real ledger's columns do.
struct MenuBarView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    /// When true, the panel shows the stored receipt strip in place of the day sheet. Set on posting
    /// and by the posted-state "View receipt" control; cleared by the strip's Done button.
    @State private var showingReceipt = false

    private var ink: Color { LedgerPalette.primaryInk(scheme) }

    var body: some View {
        Group {
            if showingReceipt, let receipt = viewModel.todaysReceipt {
                receiptPanel(receipt)
            } else {
                daySheetPanel
            }
        }
        .frame(width: 320)
        .background(LedgerPalette.surface(scheme))
        .foregroundStyle(ink)
        // The panel polls fast and animates while open, slow and label-only while closed.
        .onAppear { viewModel.panelDidAppear() }
        .onDisappear { viewModel.panelDidDisappear() }
    }

    private var daySheetPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(LedgerPalette.pencil).frame(height: 1)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(viewModel.daySheet.accounts) { account in
                    accountBlock(account)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            reconcileBar
            Rectangle().fill(LedgerPalette.pencil).frame(height: 1)
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
                Spacer()
                Button("Done") { withAnimation(.easeOut(duration: 0.15)) { showingReceipt = false } }
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(LedgerPalette.pencil).frame(height: 1)

            ScrollView(.vertical) {
                ReceiptStripView(reconciliation: receipt)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
        }
        .transition(.opacity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("DAY SHEET")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            Spacer()
            Text(viewModel.daySheet.postedByteVolume)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Account block

    @ViewBuilder
    private func accountBlock(_ account: DaySheetAccount) -> some View {
        // Account title, spanning all three columns.
        GridRow {
            Text(account.title.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(ink)
                .gridCellColumns(3)
        }

        ForEach(account.lines) { line in
            GridRow {
                Text(line.label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.85))
                Text(line.side == .debit ? line.value : "")
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .foregroundStyle(LedgerPalette.debit)
                    .gridColumnAlignment(.trailing)
                Text(line.side == .debit ? "" : line.value)
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .foregroundStyle(line.side == .credit ? LedgerPalette.credit : ink.opacity(0.55))
                    .gridColumnAlignment(.trailing)
            }
        }

        if let disclosure = account.disclosure {
            GridRow {
                Text(disclosure)
                    .font(.system(.caption2, design: .monospaced).italic())
                    .foregroundStyle(LedgerPalette.pencil)
                    .gridCellColumns(3)
            }
        }

        if account.availability == .needsPermission {
            GridRow {
                permissionAffordance.gridCellColumns(3)
            }
        }

        // Hairline rule closing the account.
        GridRow {
            Rectangle().fill(LedgerPalette.pencil).frame(height: 1).gridCellColumns(3)
        }
    }

    private var permissionAffordance: some View {
        Menu {
            Button("Grant Permission…") { viewModel.requestInputPermission() }
            Button("Open Input Monitoring Settings…") {
                PermissionsHint.openInputMonitoringSettings()
            }
        } label: {
            Label("Awaiting permission to open this account", systemImage: "lock")
                .font(.system(.caption2, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(LedgerPalette.debit)
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
