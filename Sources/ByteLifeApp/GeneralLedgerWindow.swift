import SwiftUI
import Charts
import ByteLifeCore

/// Identifier for the General Ledger scene, shared by the `Window` declaration and the footer button
/// that opens it.
enum GeneralLedgerWindow {
    static let id = "general-ledger"
}

/// Drives the Back Office day dashboard: it loads the recorded periods with their per-day activity, the
/// all-history figures for the pinned ALL TIME card, and the selected day's story and stored receipt.
/// Kept on the main actor and reload-driven rather than polled, because the back-book is a browsable
/// record rather than a live gauge, so its store queries stay off the panel's per-tick hot paths. All
/// figure, series, and normalization logic lives in ByteLifeCore (`DayStory`, `DayActivity`, `LedgerBook`,
/// `DayLabel`), so this stays a thin publisher over the store and the coordinator.
@MainActor
final class GeneralLedgerViewModel: ObservableObject {
    /// The sidebar granularity: single days, ISO weeks, or local-calendar months. Day keeps the original
    /// day dashboard; the two aggregate granularities show the period story.
    @Published private(set) var granularity: PeriodGranularity = .day
    /// The recorded days, newest first, each with its stamp state (the Day-granularity sidebar rows).
    @Published private(set) var periods: [LedgerPeriod] = []
    /// Per-day tokens and posted byte volume, normalized across the list, for the sidebar activity minis.
    @Published private(set) var activity: [DayActivityRow] = []
    /// The aggregate period rows for the Week and Month granularities, newest first.
    @Published private(set) var periodGroups: [PeriodGroup] = []
    /// The all-history figures shown in the pinned ALL TIME card.
    @Published private(set) var trialBalance: [TrialBalanceRow] = []
    /// The day whose dashboard the main pane shows in Day granularity.
    @Published private(set) var selectedDay: Int64?
    /// The selected aggregate period, keyed by its newest member epoch, in Week and Month granularity.
    @Published private(set) var selectedGroupID: Int64?
    /// The selected day's shaped dashboard: account cards, hero flow arrays, and the header hero figure.
    @Published private(set) var selectedStory: DayStory?
    /// The selected aggregate period's story: per-day bars, aggregate cards, and posted coverage.
    @Published private(set) var selectedPeriodStory: PeriodStory?
    /// The stored receipt for the selected day, or nil when the day is still open. Day granularity only;
    /// aggregate periods never compose a receipt.
    @Published private(set) var selectedReceipt: Reconciliation?
    /// The selected day's (or aggregate period's) accessory accounts: energy, focus, files, hosts, and the
    /// session/unlock memos. Day granularity carries the energy hourly bars; aggregates are figure-only.
    @Published private(set) var selectedAuxiliary: AuxiliaryStory?

    /// Today's epoch, so the header can distinguish a still-open today from a closeable past day.
    let todayEpoch: Int64
    private let coordinator: AppCoordinator
    private var postObserver: NSObjectProtocol?

    /// The recorded days newest-first and the multi-day rollups and stamps behind them, cached from the
    /// last reload so a granularity switch or an aggregate selection groups and shapes purely in memory,
    /// with no fresh store query.
    private var days: [Int64] = []
    private var totalsByDay: [Int64: [MetricKind: Int64]] = [:]
    private var stampsByDay: [Int64: String] = [:]
    /// Per-day accessory dimensions the samples table cannot carry: foreground seconds per app and the
    /// distinct-host count. Cached alongside the totals so an aggregate selection merges and sums them in
    /// memory, with no fresh store query.
    private var focusByDay: [Int64: [String: Int64]] = [:]
    private var hostsByDay: [Int64: Int] = [:]

    private var store: SampleStore { coordinator.store }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.todayEpoch = DayBucket.dayEpoch(for: Date())
        // No reload here: the view's onAppear performs the initial load, so opening the window
        // queries the store once, not twice.
        // A close from the menubar panel must refresh an already-open window, whose model is otherwise
        // reload-driven only by its own actions.
        postObserver = NotificationCenter.default.addObserver(
            forName: .byteLifeDayPosted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let postObserver { NotificationCenter.default.removeObserver(postObserver) }
    }

    /// Reloads the period list, the sidebar activity, and the all-history figures, preserving the current
    /// selection when it still exists. One multi-day rollup feeds the activity minis and, cached, every
    /// aggregate grouping and story; the all-history trial balance keeps its own single query.
    func reload() {
        days = (try? store.dayEpochsWithData()) ?? []
        stampsByDay = (try? store.reconciledStamps()) ?? [:]
        totalsByDay = (try? store.totals(forDayEpochs: days)) ?? [:]
        focusByDay = (try? store.focus(forDayEpochs: days)) ?? [:]
        hostsByDay = (try? store.distinctHosts(forDayEpochs: days)) ?? [:]
        periods = LedgerPeriod.list(daysWithData: days, stampsByDay: stampsByDay)
        activity = DayActivity.rows(daysWithData: days, totalsByDay: totalsByDay)
        trialBalance = TrialBalance.rows(totals: (try? store.trialBalance()) ?? [:])
        rebuildGroups()

        if granularity == .day {
            if selectedDay == nil || !periods.contains(where: { $0.dayEpoch == selectedDay }) {
                selectedDay = periods.first?.dayEpoch
            }
            loadDayDetail()
        } else {
            if selectedGroupID == nil || !periodGroups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = periodGroups.first?.id
            }
            loadPeriodDetail()
        }
    }

    /// Switches granularity and re-selects. Day keeps or defaults its day selection; an aggregate carries
    /// the current day into the period that contains it when possible, else selects the newest period.
    /// Purely in-memory: the cached rollups are regrouped, with no store query.
    func setGranularity(_ newValue: PeriodGranularity) {
        guard newValue != granularity else { return }
        // Carry the period on screen across the switch: from an aggregate granularity that is the
        // selected group's newest member day (so Week -> Month lands on the month containing the week
        // being viewed), from Day it is the selected day. selectedDay alone goes stale while browsing
        // aggregates, which used to make the pane jump to an unrelated period.
        let carryDay: Int64? = granularity == .day
            ? selectedDay
            : periodGroups.first(where: { $0.id == selectedGroupID })?.dayEpochs.first ?? selectedDay
        granularity = newValue
        rebuildGroups()
        if newValue == .day {
            if let carryDay, periods.contains(where: { $0.dayEpoch == carryDay }) {
                selectedDay = carryDay
            } else if selectedDay == nil || !periods.contains(where: { $0.dayEpoch == selectedDay }) {
                selectedDay = periods.first?.dayEpoch
            }
            loadDayDetail()
        } else {
            if let carryDay,
               let group = periodGroups.first(where: { $0.dayEpochs.contains(carryDay) }) {
                selectedGroupID = group.id
            } else {
                selectedGroupID = periodGroups.first?.id
            }
            loadPeriodDetail()
        }
    }

    /// Selects a day and loads its dashboard.
    func select(day: Int64) {
        selectedDay = day
        loadDayDetail()
    }

    /// Selects an aggregate period and shapes its story from the cached rollups.
    func select(group id: Int64) {
        selectedGroupID = id
        loadPeriodDetail()
    }

    /// Jumps to a day in Day granularity, the target of a coverage chip in an aggregate story.
    func jumpToDay(_ day: Int64) {
        granularity = .day
        periodGroups = []
        selectedDay = day
        loadDayDetail()
    }

    /// The activity row for a day, for the sidebar minis; nil when the day carries no recorded activity.
    func activityRow(for day: Int64) -> DayActivityRow? { activity.first { $0.dayEpoch == day } }

    /// Closes a past unposted day's books the same exactly-once way the panel closes today, then reloads
    /// so the period flips to posted and the dashboard shows the stored receipt.
    func closeBooks(day: Int64) {
        coordinator.reconcile(dayEpoch: day)
        reload()
    }

    /// Rebuilds the aggregate rows from the cached rollups for the current granularity. Day granularity
    /// uses the `periods` list, so it clears the group rows.
    private func rebuildGroups() {
        periodGroups = granularity.isAggregate
            ? PeriodGrouping.groups(daysWithData: days, granularity: granularity,
                                    totalsByDay: totalsByDay, stampsByDay: stampsByDay)
            : []
    }

    /// Builds the selected day's story from one indexed hourly query and its totals, and reads its stored
    /// receipt. An absent selection clears both.
    private func loadDayDetail() {
        guard let day = selectedDay else {
            selectedStory = nil
            selectedReceipt = nil
            selectedAuxiliary = nil
            return
        }
        selectedReceipt = (try? store.reconciliation(forDayEpoch: day)) ?? nil
        let totals = (try? store.totals(forDayEpoch: day)) ?? [:]
        let hourly = (try? store.hourlySeries(kinds: DayStory.hourlyKinds, dayEpoch: day)) ?? [:]
        // The day's typing rhythm for the Labor card, from its per-minute keystroke buckets. Day
        // granularity only; the aggregate period story omits cadence.
        let cadence = TypingCadence.from(
            minuteKeystrokes: (try? store.dayMinuteSeries(kind: .inputKeystrokes, dayEpoch: day)) ?? []
        )
        selectedStory = DayStory.build(dayEpoch: day, totals: totals, hourly: hourly, cadence: cadence)

        // The accessory accounts, with the energy per-hour bars from a single-day indexed hourly query.
        let focus = (try? store.topFocus(dayEpoch: day, limit: 5)) ?? []
        let hosts = (try? store.distinctHosts(dayEpoch: day)) ?? 0
        let energyHourly = ((try? store.hourlySeries(kinds: [.energyMilliwattHours], dayEpoch: day)) ?? [:])[.energyMilliwattHours] ?? []
        selectedAuxiliary = AuxiliaryStory.build(
            totals: totals, focus: focus, distinctHosts: hosts, energyHourly: energyHourly
        )
    }

    /// Shapes the selected aggregate period's story from the cached per-day rollups, with no store query
    /// and no hourly fetch: the aggregate charts are per-day bars drawn from the same totals the sidebar
    /// already holds. An absent selection clears the story.
    private func loadPeriodDetail() {
        guard let id = selectedGroupID,
              let group = periodGroups.first(where: { $0.id == id }) else {
            selectedPeriodStory = nil
            selectedAuxiliary = nil
            return
        }
        selectedPeriodStory = PeriodStory.build(
            label: group.label,
            dayEpochs: group.dayEpochs,
            totalsByDay: totalsByDay,
            stampsByDay: stampsByDay
        )

        // The aggregate accessory accounts: sum the accessory totals and the distinct-host counts across
        // member days, and merge the per-day focus rows into one period-wide top list. Figure-only (no
        // hourly bars), all from the cached per-day maps with no fresh store query.
        var summed: [MetricKind: Int64] = [:]
        var mergedFocus: [String: Int64] = [:]
        var hostsTotal = 0
        for day in group.dayEpochs {
            for (kind, value) in totalsByDay[day] ?? [:] { summed[kind, default: 0] += value }
            for (bundle, seconds) in focusByDay[day] ?? [:] { mergedFocus[bundle, default: 0] += seconds }
            hostsTotal += hostsByDay[day] ?? 0
        }
        selectedAuxiliary = AuxiliaryStory.build(
            totals: summed,
            focus: mergedFocus.map { (bundleId: $0.key, seconds: $0.value) },
            distinctHosts: hostsTotal
        )
    }
}

/// The Back Office: a two-pane day dashboard. A ~280pt PERIODS sidebar lists the recorded days newest
/// first, each with its stamp chip and two thin normalized activity minis so the list itself reads as a
/// history chart, and pins a compact ALL TIME card at its foot. The main pane is the selected day's
/// dashboard: a header with the full date, the day's posted byte volume hero figure, and the primary
/// action; a hero flow chart of the day's 24 hours; the five account cards (Token full width, then a 2x2
/// grid); and, for a posted day, the stored receipt strip. All chrome is adaptive via `LatticePalette`.
struct GeneralLedgerView: View {
    @StateObject private var vm = GeneralLedgerViewModel(coordinator: .shared)
    @Environment(\.colorScheme) private var scheme
    /// Whether the posted day's receipt strip renders below the account grid. Defaults visible and resets
    /// on each selection, so switching to a posted day shows its paper without a second click.
    @State private var showingReceipt = true

    private var dial: Color { LatticePalette.dial(scheme) }
    private var dim: Color { LatticePalette.dim(scheme) }

    /// A horizontal rule and a vertical rail divider, the chassis's hairlines between regions.
    private func hRule() -> some View { LatticePalette.hairline(scheme).frame(height: 1) }
    private func vRule() -> some View { LatticePalette.hairline(scheme).frame(width: 1) }

    /// The card surface panels sit on: filled card with a hairline stroke and radius 8.
    private var cardShape: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LatticePalette.card(scheme))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LatticePalette.hairline(scheme), lineWidth: 1))
    }

    /// The period under review, used to badge the day header with its stamp chip.
    private var selectedPeriod: LedgerPeriod? {
        vm.periods.first { $0.dayEpoch == vm.selectedDay }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
            vRule()
            mainPane
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(LatticePalette.chassis(scheme))
        .foregroundStyle(dial)
        .onAppear { vm.reload() }
        .onChange(of: vm.selectedDay) { _, _ in showingReceipt = true }
    }

    /// The main pane is the day dashboard in Day granularity and the aggregate period story in Week or
    /// Month granularity.
    @ViewBuilder
    private var mainPane: some View {
        if vm.granularity == .day {
            dayDashboard
        } else {
            periodDashboard
        }
    }

    // MARK: - Sidebar: periods and the ALL TIME card

    private var sidebar: some View {
        VStack(spacing: 0) {
            railHeader("PERIODS")
            granularityPicker
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            if listIsEmpty {
                Text("No periods on file yet.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        if vm.granularity == .day {
                            ForEach(vm.periods) { sidebarRow($0) }
                        } else {
                            ForEach(vm.periodGroups) { groupRow($0) }
                        }
                    }
                    .padding(10)
                }
            }
            hRule()
            allTimeCard
        }
    }

    /// True when the sidebar list for the current granularity has nothing to show.
    private var listIsEmpty: Bool {
        vm.granularity == .day ? vm.periods.isEmpty : vm.periodGroups.isEmpty
    }

    /// The Day / Week / Month segmented control, hand-built so it stays monospaced and adaptive: the
    /// selected segment fills with the card color, the rest read dim on the chassis.
    private var granularityPicker: some View {
        HStack(spacing: 0) {
            ForEach(PeriodGranularity.allCases, id: \.self) { g in
                Button {
                    vm.setGranularity(g)
                } label: {
                    Text(g.title.uppercased())
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(vm.granularity == g ? dial : dim)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(vm.granularity == g ? LatticePalette.card(scheme) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(LatticePalette.chassis(scheme))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(LatticePalette.hairline(scheme), lineWidth: 1))
        )
    }

    /// One period row: the date and a dim weekday, the stamp chip, and the two normalized activity minis
    /// (amber tokens over teal bytes). Selection gets a card fill and a 2pt teal accent edge.
    private func sidebarRow(_ period: LedgerPeriod) -> some View {
        let selected = vm.selectedDay == period.dayEpoch
        let row = vm.activityRow(for: period.dayEpoch)
        return Button {
            vm.select(day: period.dayEpoch)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(DayLabel.short(dayEpoch: period.dayEpoch))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                    Text(period.weekday)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(dim)
                    Spacer()
                    stampChip(period.state)
                }
                VStack(spacing: 3) {
                    mini(fraction: row?.tokenFraction ?? 0, color: LatticePalette.amber(scheme))
                    mini(fraction: row?.byteFraction ?? 0, color: LatticePalette.teal(scheme))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(selected))
            .overlay(alignment: .leading) { rowAccent(selected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One aggregate period row (Week or Month): the period label, its posted-coverage chip, and the same
    /// two normalized activity minis (amber tokens over teal bytes) the day rows carry, so the list reads
    /// as a history chart at any granularity. Selection gets the same card fill and teal accent edge.
    private func groupRow(_ group: PeriodGroup) -> some View {
        let selected = vm.selectedGroupID == group.id
        return Button {
            vm.select(group: group.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.label)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    coverageChip(posted: group.postedCount, total: group.dayCount)
                }
                VStack(spacing: 3) {
                    mini(fraction: group.tokenFraction, color: LatticePalette.amber(scheme))
                    mini(fraction: group.byteFraction, color: LatticePalette.teal(scheme))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowFill(selected))
            .overlay(alignment: .leading) { rowAccent(selected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The selected-row card fill, clear when unselected.
    private func rowFill(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(selected ? LatticePalette.card(scheme) : .clear)
    }

    /// The 2pt teal accent edge a selected row carries on its leading side.
    @ViewBuilder
    private func rowAccent(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 1)
                .fill(LatticePalette.teal(scheme))
                .frame(width: 2)
                .padding(.vertical, 4)
        }
    }

    /// The aggregate posted-coverage chip ("3/7"): brass-tinted and filled once every member day is
    /// posted, a dim hairline outline otherwise.
    private func coverageChip(posted: Int, total: Int) -> some View {
        let full = total > 0 && posted == total
        return chip("\(posted)/\(total)", color: full ? LedgerPalette.brass : dim, filled: full)
    }

    /// One normalized activity mini: a thin track with a fill whose width is the day's fraction of the
    /// list maximum, so the two stacked bars under each date read as a history chart.
    private func mini(fraction: Double, color: Color) -> some View {
        let clamped = min(1, max(0, fraction))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LatticePalette.hairline(scheme))
                Capsule()
                    .fill(color)
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * CGFloat(clamped)))
            }
        }
        .frame(height: 3)
    }

    /// The pinned ALL TIME card: the five accounts as account / debit / credit rows in the scheme-aware
    /// figure colors, with Distance Hauled on one indented line. Every figure is clamped to a single
    /// line so nothing wraps in the narrow sidebar.
    private var allTimeCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("ALL TIME")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("DR").frame(width: 66, alignment: .trailing)
                Text("CR").frame(width: 66, alignment: .trailing)
            }
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(dim)
            ForEach(vm.trialBalance) { row in
                allTimeRow(row)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
        .padding(10)
    }

    private func allTimeRow(_ row: TrialBalanceRow) -> some View {
        HStack(spacing: 6) {
            Text(row.isSubline ? "  \(row.label)" : row.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(row.isSubline ? dim : dial.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.debit)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(LatticePalette.debit(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 66, alignment: .trailing)
            Text(row.credit.isEmpty ? "—" : row.credit)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(row.credit.isEmpty ? dim : LatticePalette.credit(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 66, alignment: .trailing)
        }
    }

    // MARK: - Main pane: the day dashboard

    @ViewBuilder
    private var dayDashboard: some View {
        if let story = vm.selectedStory, let day = vm.selectedDay {
            VStack(spacing: 0) {
                dashboardHeader(story: story, day: day)
                hRule()
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        heroDayChart(story)
                        accountCard(story.cards[0])          // Token, full width
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(Array(story.cards.dropFirst()), content: accountCard)
                        }
                        if let aux = vm.selectedAuxiliary {
                            auxiliarySection(aux, showEnergyBars: true)
                        }
                        if let receipt = vm.selectedReceipt, showingReceipt {
                            receiptSection(receipt)
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            emptyState
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12, alignment: .top),
         GridItem(.flexible(), spacing: 12, alignment: .top)]
    }

    /// The day header: the full date with its stamp chip, a small status line, the posted-volume hero
    /// figure, and the primary action.
    private func dashboardHeader(story: DayStory, day: Int64) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(DayLabel.full(dayEpoch: day))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                    if let period = selectedPeriod { stampChip(period.state) }
                }
                if let status = statusLine(day: day) {
                    Text(status)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(dim)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(story.postedByteVolume)
                    .font(.system(size: 24, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(dial)
                Text("POSTED BYTE VOLUME")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dim)
            }
            primaryAction(day: day)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// The dim status line under the date: unposted days say whether the period is still open or a past
    /// period awaiting posting; a posted day says nothing, because its stamp chip already reads.
    private func statusLine(day: Int64) -> String? {
        guard vm.selectedReceipt == nil else { return nil }
        return day == vm.todayEpoch ? "Period still open." : "Past period, unposted."
    }

    /// "Close the books" for an unposted day, or the Share / Save receipt toolbar plus a View-receipt
    /// toggle for a posted one.
    @ViewBuilder
    private func primaryAction(day: Int64) -> some View {
        if let receipt = vm.selectedReceipt {
            HStack(spacing: 12) {
                ReceiptToolbar(reconciliation: receipt)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showingReceipt.toggle() }
                } label: {
                    Text(showingReceipt ? "Hide receipt" : "View receipt")
                        .font(.system(.caption, design: .monospaced))
                }
            }
        } else {
            Button {
                vm.closeBooks(day: day)
            } label: {
                Text("Close the books")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }
        }
    }

    // MARK: - Hero day chart

    private struct HourPoint: Identifiable {
        let series: String
        let hour: Int
        let value: Double
        var id: String { "\(series)-\(hour)" }
    }

    /// The day's 24 hourly Traffic and Storage totals as the deck's two-series area chart on one shared
    /// byte scale (teal traffic, violet storage), with a floor on the domain so an idle day reads flat
    /// and hour marks at 0/6/12/18/24 in dim text.
    private func heroDayChart(_ story: DayStory) -> some View {
        var points: [HourPoint] = []
        points += story.trafficHourly.enumerated().map {
            HourPoint(series: "traffic", hour: $0.offset, value: Double($0.element))
        }
        points += story.storageHourly.enumerated().map {
            HourPoint(series: "storage", hour: $0.offset, value: Double($0.element))
        }
        let maxY = max(Double((story.trafficHourly + story.storageHourly).max() ?? 0), 65_536)

        return Chart(points) { point in
            AreaMark(
                x: .value("Hour", point.hour),
                y: .value("Bytes", point.value),
                series: .value("Series", point.series)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(by: .value("Series", point.series))
            .opacity(0.22)

            LineMark(
                x: .value("Hour", point.hour),
                y: .value("Bytes", point.value),
                series: .value("Series", point.series)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .foregroundStyle(by: .value("Series", point.series))
        }
        .chartForegroundStyleScale([
            "traffic": LatticePalette.teal(scheme),
            "storage": LatticePalette.violet(scheme),
        ])
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...maxY)
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine().foregroundStyle(LatticePalette.hairline(scheme))
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text("\(hour)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(dim)
                    }
                }
            }
        }
        .frame(height: 62)
        .padding(10)
        .background(cardShape)
    }

    // MARK: - Account cards

    /// One account card: a channel-colored title, the day total right-aligned, the 24 hourly bars in the
    /// channel color, and the account's compact figure rows in the debit/credit/memo colors.
    private func accountCard(_ card: DayStoryCard) -> some View {
        let color = channelColor(card.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.title.uppercased())
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Spacer()
                Text(card.headline)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(dial)
                    .lineLimit(1)
            }
            channelBars(card.hourly, color: color)
            VStack(spacing: 3) {
                ForEach(card.lines) { line in
                    figureRow(line)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    /// A strip of thin bars in the channel color, each normalized to the strip's own peak so the shape
    /// reads even when a single account dominates the byte volume. Shared by a day's 24 hourly bars and an
    /// aggregate period's per-day bars, since both are just a channel amount over an ordered window.
    private func channelBars(_ values: [Int64], color: Color) -> some View {
        let maxV = max(values.max() ?? 0, 1)
        return Canvas { context, size in
            let n = max(values.count, 1)
            let gap: CGFloat = 1.5
            let barW = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for (i, v) in values.enumerated() {
                let h = v > 0 ? max(1, size.height * CGFloat(Double(v) / Double(maxV))) : 0
                guard h > 0 else { continue }
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: size.height - h, width: barW, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(color))
            }
        }
        .frame(height: 28)
    }

    /// One compact figure row: the label and its value, the value colored by its ledger side and clamped
    /// to a single line so a long figure (Distance Hauled) never wraps.
    private func figureRow(_ line: DaySheetLine) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(line.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(line.value)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(figureColor(line.side))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Receipt

    /// The posted day's stored receipt strip on the chassis with the same Share / Save toolbar, shown
    /// below the account grid when the header's View-receipt toggle is on.
    private func receiptSection(_ receipt: Reconciliation) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("RECEIPT")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(dim)
                Spacer()
                ReceiptToolbar(reconciliation: receipt)
            }
            ReceiptStripView(reconciliation: receipt, fontSize: 12)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    // MARK: - Main pane: the aggregate period dashboard

    /// The aggregate story shown for a Week or Month selection: a header with the period label, coverage
    /// chip, and posted-volume hero; a hero chart of per-day traffic/storage bars across the period; the
    /// aggregate account cards (Token full width, then a 2x2 grid) with per-day mini bars; and, in place of
    /// the receipt, a posted-coverage card whose day chips jump back to Day granularity. Aggregate periods
    /// never compose a receipt and never show a Close action.
    @ViewBuilder
    private var periodDashboard: some View {
        if let story = vm.selectedPeriodStory, !story.days.isEmpty {
            VStack(spacing: 0) {
                periodHeader(story)
                hRule()
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        periodHeroChart(story)
                        periodAccountCard(story.cards[0])        // Token, full width
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(Array(story.cards.dropFirst()), content: periodAccountCard)
                        }
                        if let aux = vm.selectedAuxiliary {
                            auxiliarySection(aux, showEnergyBars: false)
                        }
                        coverageSection(story)
                    }
                    .padding(16)
                }
            }
        } else {
            emptyState
        }
    }

    /// The period header: the label with its coverage chip, a day-count status line, and the aggregate
    /// posted-volume hero figure. There is no primary action, because an aggregate period never posts.
    private func periodHeader(_ story: PeriodStory) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(story.label)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                    coverageChip(posted: story.postedCount, total: story.dayCount)
                }
                Text(story.dayCount == 1 ? "1 recorded day" : "\(story.dayCount) recorded days")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dim)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(story.postedByteVolume)
                    .font(.system(size: 24, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(dial)
                Text("POSTED BYTE VOLUME")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private struct DayBar: Identifiable {
        let series: String
        let day: Int
        let value: Double
        var id: String { "\(series)-\(day)" }
    }

    /// The period's per-day Traffic and Storage totals as grouped bars on one shared byte scale (teal
    /// traffic, violet storage), with day-of-month axis marks. Drawn from the period story's per-day
    /// arrays, so it needs no hourly fetch.
    private func periodHeroChart(_ story: PeriodStory) -> some View {
        // Bars plot by chronological index, never by day-of-month: a week crossing a month boundary
        // (Jun 29 - Jul 5) must read left-to-right in time, not scrambled by calendar numbering. The
        // axis labels translate the index back to the day-of-month.
        var bars: [DayBar] = []
        for i in story.days.indices {
            bars.append(DayBar(series: "traffic", day: i, value: Double(story.trafficPerDay[i])))
            bars.append(DayBar(series: "storage", day: i, value: Double(story.storagePerDay[i])))
        }
        return Chart(bars) { bar in
            BarMark(
                x: .value("Day", bar.day),
                y: .value("Bytes", bar.value),
                width: .fixed(6)
            )
            .foregroundStyle(by: .value("Series", bar.series))
            .position(by: .value("Series", bar.series))
        }
        .chartForegroundStyleScale([
            "traffic": LatticePalette.teal(scheme),
            "storage": LatticePalette.violet(scheme),
        ])
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(LatticePalette.hairline(scheme))
                AxisValueLabel {
                    if let index = value.as(Int.self), story.days.indices.contains(index) {
                        Text("\(story.days[index].dayOfMonth)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(dim)
                    }
                }
            }
        }
        .frame(height: 90)
        .padding(10)
        .background(cardShape)
    }

    /// One aggregate account card: the channel-colored title, the period total right-aligned, the per-day
    /// bars in the channel color, and the account's aggregate figure rows in the debit/credit/memo colors.
    /// The same card structure as a day's, with the bar strip reading per day instead of per hour.
    private func periodAccountCard(_ card: PeriodStoryCard) -> some View {
        let color = channelColor(card.kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.title.uppercased())
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Spacer()
                Text(card.headline)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(dial)
                    .lineLimit(1)
            }
            channelBars(card.perDay, color: color)
            VStack(spacing: 3) {
                ForEach(card.lines) { line in
                    figureRow(line)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    /// The posted-coverage card that stands in for the receipt on an aggregate period: the coverage line
    /// ("3 of 7 days posted") over a wrapping row of the member days' stamp chips. Clicking a chip switches
    /// to Day granularity and selects that day.
    private func coverageSection(_ story: PeriodStory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COVERAGE")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(dim)
                Spacer()
                Text(story.coverageText)
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(story.fullyPosted ? LedgerPalette.brass : dim)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 66), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(story.days) { day in
                    dayCoverageChip(day)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    /// One member day as a clickable stamp chip: a posted day tints filled in its stamp color, an open day
    /// reads as a dim hairline outline. Tapping it jumps to that day in Day granularity.
    private func dayCoverageChip(_ day: PeriodDay) -> some View {
        let color: Color
        let filled: Bool
        switch day.state {
        case .posted(let stamp):
            color = stampColor(stamp)
            filled = true
        case .unposted:
            color = dim
            filled = false
        }
        return Button {
            vm.jumpToDay(day.dayEpoch)
        } label: {
            chip(DayLabel.short(dayEpoch: day.dayEpoch), color: color, filled: filled)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Auxiliary accounts

    /// The accessory accounts booked alongside the five ledger accounts: the Energy Account, the Focus
    /// Account (its top apps with horizontal bars), Files Touched and Hosts Contacted figures, and the
    /// EXPOSURE session/unlock memos. Shaped entirely by `AuxiliaryStory`; this only lays it out. Energy
    /// per-hour bars show on a single day (`showEnergyBars`) and are omitted for an aggregate period.
    private func auxiliarySection(_ aux: AuxiliaryStory, showEnergyBars: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ALSO ON THE BOOKS")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(dim)
                Spacer()
            }
            energyCard(aux, showBars: showEnergyBars)
            focusCard(aux)
            LazyVGrid(columns: gridColumns, spacing: 12) {
                auxFigureCard(label: "FILES TOUCHED",
                              value: aux.filesPresent ? ByteFormatting.grouped(aux.filesTouched) : "—",
                              present: aux.filesPresent, color: LatticePalette.violet(scheme))
                auxFigureCard(label: "HOSTS CONTACTED",
                              value: aux.distinctHosts.map { ByteFormatting.grouped(Int64($0)) } ?? "—",
                              present: aux.distinctHosts != nil, color: LatticePalette.teal(scheme))
                auxFigureCard(label: "SESSIONS", value: ByteFormatting.grouped(aux.sessions),
                              present: true, color: LatticePalette.green(scheme))
                auxFigureCard(label: "UNLOCKS", value: ByteFormatting.grouped(aux.unlocks),
                              present: true, color: LatticePalette.green(scheme))
            }
        }
    }

    /// The Energy Account: its watt-hour headline, and on a single day the per-hour amber bars from the
    /// energy minute buckets. An account that never booked energy reads dim.
    private func energyCard(_ aux: AuxiliaryStory, showBars: Bool) -> some View {
        let color = LatticePalette.amber(scheme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ENERGY ACCOUNT")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text(aux.energyHeadline)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(aux.energyPresent ? dial : dim)
            }
            if showBars, aux.energyHourly.contains(where: { $0 > 0 }) {
                channelBars(aux.energyHourly, color: color)
            } else if !aux.energyPresent {
                Text("Account not yet opened.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    /// The Focus Account: the top apps by foreground time, each a name, a horizontal bar of its share of
    /// the leader, and its time. An empty list reads as unopened.
    private func focusCard(_ aux: AuxiliaryStory) -> some View {
        let color = LatticePalette.teal(scheme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FOCUS ACCOUNT")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
            }
            if aux.focusApps.isEmpty {
                Text("Account not yet opened.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(dim)
            } else {
                VStack(spacing: 6) {
                    ForEach(aux.focusApps) { app in
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(dial.opacity(0.85))
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            mini(fraction: app.fraction, color: color)
                            Text(app.timeLabel)
                                .font(.system(.caption2, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(dim)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    /// One small figure card in the accessory grid: a channel-colored label over a right-reading figure,
    /// dim when the sensor did not report.
    private func auxFigureCard(label: String, value: String, present: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(present ? dial : dim)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 34))
                .foregroundStyle(dim)
            Text("No periods on file yet.")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            Text("ByteLife records as it runs; a day appears here once it holds data.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(dim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Stamp chip

    /// The stamp state as a small chip. The stamp color rule is unchanged: brass only for BALANCED,
    /// oxblood only for FLAGGED, dial ink for an arrears posting; an open day reads dim in a hairline
    /// style (an outline rather than a fill).
    @ViewBuilder
    private func stampChip(_ state: PeriodState) -> some View {
        switch state {
        case .posted(let stamp):
            chip(stamp == "POSTED IN ARREARS" ? "ARREARS" : stamp, color: stampColor(stamp), filled: true)
        case .unposted:
            chip("OPEN", color: dim, filled: false)
        }
    }

    private func stampColor(_ stamp: String) -> Color {
        switch stamp {
        case "BALANCED": return LedgerPalette.brass
        case "FLAGGED": return LatticePalette.debit(scheme)
        default: return dial
        }
    }

    /// A small rounded badge in `color`. Filled chips tint their background; the hairline OPEN chip leaves
    /// it clear and reads as an outline.
    private func chip(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(filled ? color.opacity(0.16) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color.opacity(filled ? 0.35 : 0.5), lineWidth: 1)
                    )
            )
    }

    // MARK: - Shared

    /// The channel signal color for an account, matching the deck: Token amber, Traffic teal, Storage
    /// violet, Hours green, Labor coral.
    private func channelColor(_ kind: LedgerAccountKind) -> Color {
        switch kind {
        case .token: return LatticePalette.amber(scheme)
        case .traffic: return LatticePalette.teal(scheme)
        case .storage: return LatticePalette.violet(scheme)
        case .hours: return LatticePalette.green(scheme)
        case .labor: return LatticePalette.coral(scheme)
        }
    }

    /// A figure's color by its ledger side: debit oxblood, credit green, memo dim.
    private func figureColor(_ side: LedgerSide) -> Color {
        switch side {
        case .debit: return LatticePalette.debit(scheme)
        case .credit: return LatticePalette.credit(scheme)
        case .memo: return dim
        }
    }

    private func railHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
            hRule()
        }
    }
}
