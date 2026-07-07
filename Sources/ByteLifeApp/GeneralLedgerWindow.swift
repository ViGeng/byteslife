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
    /// The recorded days, newest first, each with its stamp state.
    @Published private(set) var periods: [LedgerPeriod] = []
    /// Per-day tokens and posted byte volume, normalized across the list, for the sidebar activity minis.
    @Published private(set) var activity: [DayActivityRow] = []
    /// The all-history figures shown in the pinned ALL TIME card.
    @Published private(set) var trialBalance: [TrialBalanceRow] = []
    /// The day whose dashboard the main pane shows.
    @Published private(set) var selectedDay: Int64?
    /// The selected day's shaped dashboard: account cards, hero flow arrays, and the header hero figure.
    @Published private(set) var selectedStory: DayStory?
    /// The stored receipt for the selected day, or nil when the day is still open.
    @Published private(set) var selectedReceipt: Reconciliation?

    /// Today's epoch, so the header can distinguish a still-open today from a closeable past day.
    let todayEpoch: Int64
    private let coordinator: AppCoordinator
    private var postObserver: NSObjectProtocol?

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
    /// selection when it still exists. One multi-day rollup feeds the activity minis; the all-history
    /// trial balance keeps its own single query.
    func reload() {
        let days = (try? store.dayEpochsWithData()) ?? []
        let stamps = (try? store.reconciledStamps()) ?? [:]
        let totalsByDay = (try? store.totals(forDayEpochs: days)) ?? [:]
        periods = LedgerPeriod.list(daysWithData: days, stampsByDay: stamps)
        activity = DayActivity.rows(daysWithData: days, totalsByDay: totalsByDay)
        trialBalance = TrialBalance.rows(totals: (try? store.trialBalance()) ?? [:])

        if selectedDay == nil || !periods.contains(where: { $0.dayEpoch == selectedDay }) {
            selectedDay = periods.first?.dayEpoch
        }
        loadDetail()
    }

    /// Selects a period and loads its dashboard.
    func select(day: Int64) {
        selectedDay = day
        loadDetail()
    }

    /// The activity row for a day, for the sidebar minis; nil when the day carries no recorded activity.
    func activityRow(for day: Int64) -> DayActivityRow? { activity.first { $0.dayEpoch == day } }

    /// Closes a past unposted day's books the same exactly-once way the panel closes today, then reloads
    /// so the period flips to posted and the dashboard shows the stored receipt.
    func closeBooks(day: Int64) {
        coordinator.reconcile(dayEpoch: day)
        reload()
    }

    /// Builds the selected day's story from one indexed hourly query and its totals, and reads its stored
    /// receipt. An absent selection clears both.
    private func loadDetail() {
        guard let day = selectedDay else {
            selectedStory = nil
            selectedReceipt = nil
            return
        }
        selectedReceipt = (try? store.reconciliation(forDayEpoch: day)) ?? nil
        let totals = (try? store.totals(forDayEpoch: day)) ?? [:]
        let hourly = (try? store.hourlySeries(kinds: DayStory.hourlyKinds, dayEpoch: day)) ?? [:]
        selectedStory = DayStory.build(dayEpoch: day, totals: totals, hourly: hourly)
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
            dayDashboard
                .frame(minWidth: 660, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(LatticePalette.chassis(scheme))
        .foregroundStyle(dial)
        .onAppear { vm.reload() }
        .onChange(of: vm.selectedDay) { _, _ in showingReceipt = true }
    }

    // MARK: - Sidebar: periods and the ALL TIME card

    private var sidebar: some View {
        VStack(spacing: 0) {
            railHeader("PERIODS")
            if vm.periods.isEmpty {
                Text("No periods on file yet.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.periods) { period in
                            sidebarRow(period)
                        }
                    }
                    .padding(10)
                }
            }
            hRule()
            allTimeCard
        }
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
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? LatticePalette.card(scheme) : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LatticePalette.teal(scheme))
                        .frame(width: 2)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            hourlyBars(card.hourly, color: color)
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

    /// The 24 hourly amounts as thin bars in the channel color, each normalized to the card's own peak so
    /// the day's shape reads even when a single account dominates the byte volume.
    private func hourlyBars(_ values: [Int64], color: Color) -> some View {
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
