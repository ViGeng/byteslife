import SwiftUI
import ByteLifeCore

/// Identifier for the General Ledger scene, shared by the `Window` declaration and the footer button
/// that opens it.
enum GeneralLedgerWindow {
    static let id = "general-ledger"
}

/// Drives the General Ledger window: it loads the recorded periods and the all-history trial balance
/// from the store, tracks the selected day and account, and posts a past day's receipt on request. Kept
/// on the main actor and reload-driven rather than polled, because the back-book is a browsable record
/// rather than a live gauge. All figure and column logic lives in ByteLifeCore, so this stays a thin
/// publisher over the store and the coordinator.
@MainActor
final class GeneralLedgerViewModel: ObservableObject {
    /// The recorded days, newest first, each with its stamp state.
    @Published private(set) var periods: [LedgerPeriod] = []
    /// The all-history trial balance rows for the right rail.
    @Published private(set) var trialBalance: [TrialBalanceRow] = []
    /// The day whose detail the center-right pane shows.
    @Published private(set) var selectedDay: Int64?
    /// The stored receipt for the selected day, or nil when the day is still open.
    @Published private(set) var selectedReceipt: Reconciliation?
    /// The read-only day sheet for the selected unposted day, or nil when the day is posted.
    @Published private(set) var selectedSheet: DaySheet?
    /// The left-rail account the user highlighted. Cosmetic in this iteration.
    @Published var highlightedAccount: LedgerAccountKind?

    /// Today's epoch, so the detail pane can distinguish a still-open today from a closeable past day.
    let todayEpoch: Int64
    private let coordinator: AppCoordinator
    private var postObserver: NSObjectProtocol?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.todayEpoch = DayBucket.dayEpoch(for: Date())
        reload()
        // A close from the menubar panel must refresh an already-open window, whose model is
        // otherwise reload-driven only by its own actions.
        postObserver = NotificationCenter.default.addObserver(
            forName: .byteLifeDayPosted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let postObserver { NotificationCenter.default.removeObserver(postObserver) }
    }

    /// Reloads the period list and trial balance, preserving the current selection when it still exists.
    func reload() {
        let days = (try? coordinator.store.dayEpochsWithData()) ?? []
        let stamps = (try? coordinator.store.reconciledStamps()) ?? [:]
        periods = LedgerPeriod.list(daysWithData: days, stampsByDay: stamps)
        trialBalance = TrialBalance.rows(totals: (try? coordinator.store.trialBalance()) ?? [:])

        if selectedDay == nil || !periods.contains(where: { $0.dayEpoch == selectedDay }) {
            selectedDay = periods.first?.dayEpoch
        }
        loadDetail()
    }

    /// Selects a period and loads its detail.
    func select(day: Int64) {
        selectedDay = day
        loadDetail()
    }

    /// Closes a past unposted day's books the same exactly-once way the panel closes today, then reloads
    /// so the row flips to posted and the detail shows the stored receipt.
    func closeBooks(day: Int64) {
        coordinator.reconcile(dayEpoch: day)
        reload()
    }

    private func loadDetail() {
        guard let day = selectedDay else {
            selectedReceipt = nil
            selectedSheet = nil
            return
        }
        let receipt = (try? coordinator.store.reconciliation(forDayEpoch: day)) ?? nil
        selectedReceipt = receipt
        if receipt == nil {
            let totals = (try? coordinator.store.totals(forDayEpoch: day)) ?? [:]
            // No availability map: a historical read-only sheet shows figures without live badges or
            // permission affordances, which belong to the open day in the panel.
            selectedSheet = DaySheet.build(totals: totals, availabilityByFamily: [:], reconciliation: nil)
        } else {
            selectedSheet = nil
        }
    }
}

/// The General Ledger: a document-style window laid out like a bound accounting book. A left rail of the
/// five accounts, a center column of recorded periods newest-first with their stamp state, a day-detail
/// pane showing the stored receipt strip for a posted day or a read-only day sheet with a Close-the-books
/// action for an unposted one, and a right rail carrying the all-history trial balance.
struct GeneralLedgerView: View {
    @StateObject private var vm = GeneralLedgerViewModel(coordinator: .shared)
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { LedgerPalette.primaryInk(scheme) }
    private func hairline() -> some View { Rectangle().fill(LedgerPalette.pencil).frame(width: 1) }

    var body: some View {
        HStack(spacing: 0) {
            accountsRail
                .frame(width: 180)
            hairline()
            periodsColumn
                .frame(width: 210)
            hairline()
            detailPane
                .frame(minWidth: 340, maxWidth: .infinity)
            hairline()
            trialBalanceRail
                .frame(width: 268)
        }
        .frame(minWidth: 940, minHeight: 520)
        .background(LedgerPalette.surface(scheme))
        .foregroundStyle(ink)
        .onAppear { vm.reload() }
    }

    // MARK: - Left rail: accounts

    private var accountsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("ACCOUNTS")
            ForEach(LedgerAccountKind.allCases, id: \.rawValue) { kind in
                Button {
                    vm.highlightedAccount = kind
                } label: {
                    Text(kind.title)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(vm.highlightedAccount == kind ? LedgerPalette.pencil.opacity(0.28) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Center: recorded periods

    private var periodsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("PERIODS")
            if vm.periods.isEmpty {
                Text("No periods on file yet.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LedgerPalette.pencil)
                    .padding(14)
            }
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(vm.periods) { period in
                        periodRow(period)
                        Rectangle().fill(LedgerPalette.pencil.opacity(0.5)).frame(height: 1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func periodRow(_ period: LedgerPeriod) -> some View {
        Button {
            vm.select(day: period.dayEpoch)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(period.dateLabel)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Text(period.weekday)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.6))
                }
                Spacer()
                stampBadge(period.state)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(vm.selectedDay == period.dayEpoch ? LedgerPalette.pencil.opacity(0.28) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stampBadge(_ state: PeriodState) -> some View {
        switch state {
        case .posted(let stamp):
            // Brass gold marks the balanced close and nothing else; a flagged day reads in oxblood
            // and an arrears posting in plain ink. The long arrears stamp shortens to fit the column.
            Text(stamp == "POSTED IN ARREARS" ? "ARREARS" : stamp)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(
                    stamp == "BALANCED" ? LedgerPalette.brass
                        : stamp == "FLAGGED" ? LedgerPalette.debit : ink
                )
        case .unposted:
            Text("OPEN")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(LedgerPalette.pencil)
        }
    }

    // MARK: - Day detail

    @ViewBuilder
    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("DAY DETAIL")
            if let receipt = vm.selectedReceipt {
                ScrollView(.vertical) {
                    ReceiptStripView(reconciliation: receipt, fontSize: 12)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            } else if let sheet = vm.selectedSheet, let day = vm.selectedDay {
                unpostedDetail(sheet: sheet, day: day)
            } else {
                Text("Select a period to review.")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(LedgerPalette.pencil)
                    .padding(18)
                Spacer()
            }
        }
    }

    /// A read-only day sheet for an unposted period, with the Close-the-books action that composes and
    /// posts that day's receipt exactly once.
    private func unpostedDetail(sheet: DaySheet, day: Int64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(sheet.accounts) { account in
                        GridRow {
                            Text(account.title.uppercased())
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
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
                                    .foregroundStyle(LedgerPalette.debit)
                                    .gridColumnAlignment(.trailing)
                                Text(line.side == .debit ? "" : line.value)
                                    .font(.system(.caption2, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(line.side == .credit ? LedgerPalette.credit : ink.opacity(0.55))
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                        GridRow {
                            Rectangle().fill(LedgerPalette.pencil).frame(height: 1).gridCellColumns(3)
                        }
                    }
                }
                .padding(16)
            }

            Rectangle().fill(LedgerPalette.pencil).frame(height: 1)
            HStack {
                Text(day == vm.todayEpoch ? "Period still open." : "Past period, unposted.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(LedgerPalette.pencil)
                Spacer()
                Button {
                    vm.closeBooks(day: day)
                } label: {
                    Text("Close the books")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Right rail: trial balance

    private var trialBalanceRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("TRIAL BALANCE")
            HStack {
                Text("ACCOUNT")
                Spacer()
                Text("DEBIT").frame(width: 74, alignment: .trailing)
                Text("CREDIT").frame(width: 74, alignment: .trailing)
            }
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(ink.opacity(0.6))
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            Rectangle().fill(LedgerPalette.pencil).frame(height: 1)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(vm.trialBalance) { row in
                        trialRow(row)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func trialRow(_ row: TrialBalanceRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.label)
                .font(.system(.caption2, design: .monospaced).weight(row.isSubline ? .regular : .medium))
                .foregroundStyle(row.isSubline ? ink.opacity(0.7) : ink)
                .padding(.leading, row.isSubline ? 12 : 0)
            Spacer()
            Text(row.debit)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(LedgerPalette.debit)
                .frame(width: 74, alignment: .trailing)
            Text(row.credit.isEmpty ? "—" : row.credit)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(row.credit.isEmpty ? ink.opacity(0.4) : LedgerPalette.credit)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: - Shared

    private func railHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
            Rectangle().fill(LedgerPalette.pencil).frame(height: 1)
        }
    }
}
