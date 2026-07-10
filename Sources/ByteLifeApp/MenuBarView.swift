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

        // The General Ledger opens as its own window: the Back Office day dashboard.
        Window("General Ledger", id: GeneralLedgerWindow.id) {
            GeneralLedgerView()
        }

        // The Receipt window is value-presented by accounting day: the stable, titled host from which a
        // receipt shares (so compose targets like Messages keep their session). One window per day; a
        // repeat Share for the same day raises the existing one.
        WindowGroup(id: ReceiptWindow.id, for: Int64.self) { $dayEpoch in
            if let dayEpoch {
                ReceiptWindowView(dayEpoch: dayEpoch)
            }
        }
        .windowResizability(.contentSize)
    }
}

/// The menubar panel: the live Meter Bridge instrument on a fixed dark faceplate, with the receipt bar
/// and footer beneath it. The bridge reads live rates and history bars; the record layer needs no act
/// anymore (the books keep themselves), so the bar under the meter only discloses that today is open
/// and offers its provisional receipt. The panel is always dark regardless of the system appearance,
/// the way real hardware has a fixed face.
struct MenuBarView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    /// The persisted LIVE toggle, shared by key with the header chip. Read on open to pick the cadence.
    @AppStorage("liveMode") private var liveMode = true

    private var ink: Color { LatticePalette.dial(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeterBridgeView(viewModel: viewModel)
            auxiliaryStrip
            receiptBar
            Rectangle().fill(LatticePalette.hairline(scheme)).frame(height: 1)
            footer
        }
        .frame(width: 360, alignment: .leading)
        .background(LatticePalette.chassis(scheme))
        .foregroundStyle(ink)
        // The panel polls fast and animates while open in live mode, slow and label-only otherwise.
        .onAppear { viewModel.panelDidAppear(live: liveMode) }
        .onDisappear { viewModel.panelDidDisappear() }
    }

    // MARK: - Also on the books

    /// The compact ALSO ON THE BOOKS strip: the day's accessory figures as small card chips (energy, top
    /// app, files, hosts, unlocks). Figures only, no charts; a sensor that did not report reads as a dim
    /// dash. Shaped entirely by `AuxiliaryStrip` in the core, so this view only lays the chips out.
    @ViewBuilder
    private var auxiliaryStrip: some View {
        let chips = viewModel.auxiliaryStrip.chips
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("ALSO ON THE BOOKS")
                    .font(.system(size: 9, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LatticePalette.dim(scheme))
                HStack(spacing: 6) {
                    ForEach(chips) { auxChip($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func auxChip(_ chip: AuxiliaryChip) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(chip.label)
                .font(.system(size: 8, design: .monospaced).weight(.medium))
                .foregroundStyle(LatticePalette.dim(scheme))
            Text(chip.value)
                .font(.system(size: 10, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(chip.present ? LatticePalette.dial(scheme) : LatticePalette.dim(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LatticePalette.card(scheme))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LatticePalette.hairline(scheme), lineWidth: 1))
        )
    }

    // MARK: - Receipt bar

    /// The record layer under the meter. The books keep themselves now: today is always open (it seals
    /// itself at midnight, and yesterday is always posted), so the bar discloses the open state and
    /// offers today's provisional receipt in the stable Receipt window.
    private var receiptBar: some View {
        HStack {
            Text("DAY OPEN")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(LatticePalette.dim(scheme))
            Spacer()
            Button {
                openWindow(id: ReceiptWindow.id, value: DayBucket.dayEpoch(for: Date()))
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("View receipt")
                    .font(.system(.caption, design: .monospaced))
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
