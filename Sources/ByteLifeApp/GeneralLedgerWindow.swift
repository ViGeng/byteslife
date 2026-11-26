import AppKit
import SwiftUI
import ByteLifeCore

enum GeneralLedgerWindow {
    static let id = "general-ledger"
}

struct GeneralLedgerView: View {
    private enum BrowseMode: String, CaseIterable {
        case date = "By Date"
        case metric = "By Metric"
    }

    @StateObject private var vm = GeneralLedgerViewModel(coordinator: .shared)
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    @State private var mode = BrowseMode.date
    @State private var dateModule: LedgerModule?
    @State private var historyModule = LedgerModule.traffic
    @State private var historyPreferences = LedgerHistoryView.Preferences()
    @State private var showingTrialBalance = false

    private var dim: Color { LatticePalette.dim(scheme) }
    private var selectedPeriod: LedgerPeriod? { vm.periods.first { $0.dayEpoch == vm.selectedDay } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 222)
            Divider()
            Group {
                switch mode {
                case .date: dateWorkspace
                case .metric:
                    LedgerHistoryView(vm: vm, module: historyModule, preferences: $historyPreferences) { day in
                        openDay(day, module: historyModule)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LatticePalette.card(scheme))
        }
        .frame(minWidth: 940, minHeight: 600)
        .background(LatticePalette.chassis(scheme))
        .foregroundStyle(LatticePalette.dial(scheme))
        .onAppear { vm.reload() }
        .onChange(of: mode) { _, newValue in
            if newValue == .metric { vm.reloadHistory() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Browse ledger", selection: $mode) {
                ForEach(BrowseMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            switch mode {
            case .date: dateSidebar
            case .metric: metricSidebar
            }

            Divider()
            HStack {
                Button {
                    showingTrialBalance.toggle()
                } label: {
                    Label("Trial balance", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingTrialBalance, arrowEdge: .bottom) { trialBalance }
                Spacer()
                Button {
                    vm.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh ledger")
                .help("Refresh ledger")
            }
            .font(.callout)
            .padding(14)
        }
    }

    private var dateSidebar: some View {
        VStack(spacing: 8) {
            Picker("Period", selection: Binding(get: { vm.granularity }, set: { granularity in
                dateModule = nil
                vm.setGranularity(granularity)
            })) {
                ForEach(PeriodGranularity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if vm.granularity == .day {
                        ForEach(vm.periods) { period in
                            let isToday = period.dayEpoch == vm.todayEpoch
                            sidebarButton(selected: vm.selectedDay == period.dayEpoch) {
                                dateModule = nil
                                vm.select(day: period.dayEpoch)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(isToday ? "Today" : DayLabel.short(dayEpoch: period.dayEpoch))
                                        .font(.callout.weight(.medium))
                                    Text(isToday ? DayLabel.short(dayEpoch: period.dayEpoch) : period.weekday)
                                        .font(.caption)
                                        .foregroundStyle(dim)
                                }
                                Spacer()
                            }
                            .help(DayLabel.full(dayEpoch: period.dayEpoch))
                        }
                    } else if vm.periodGroups.isEmpty {
                        Text("No recorded periods")
                            .font(.callout)
                            .foregroundStyle(dim)
                            .padding(12)
                    } else {
                        ForEach(vm.periodGroups) { period in
                            sidebarButton(selected: vm.selectedGroupID == period.id) {
                                dateModule = nil
                                vm.select(group: period.id)
                            } label: {
                                Text(period.label)
                                    .font(.callout.weight(.medium))
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var metricSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(LedgerModule.allCases) { module in
                sidebarButton(selected: historyModule == module) {
                    historyModule = module
                } label: {
                    module.icon(scheme)
                    Text(module.rawValue).font(.callout.weight(.medium))
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func sidebarButton<Label: View>(
        selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9, content: label)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? LatticePalette.dial(scheme).opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var dateWorkspace: some View {
        if vm.granularity == .day, let story = vm.selectedStory, let period = selectedPeriod {
            let isToday = period.dayEpoch == vm.todayEpoch
            let status = dayStatus(period.state, isToday: isToday)
            datePage(title: isToday ? "Today" : DayLabel.short(dayEpoch: period.dayEpoch),
                     subtitle: "\(DayLabel.full(dayEpoch: period.dayEpoch)) · \(status)",
                     volume: story.postedByteVolume,
                     receiptDay: isToday || period.isPosted ? period.dayEpoch : nil)
                .id(period.dayEpoch)
        } else if vm.granularity.isAggregate, let story = vm.selectedPeriodStory {
            datePage(title: story.label,
                     subtitle: story.dayCount == 1 ? "1 recorded day" : "\(story.dayCount) recorded days",
                     volume: story.postedByteVolume, receiptDay: nil)
                .id(vm.selectedGroupID)
        } else {
            ContentUnavailableView("No recorded periods", systemImage: "calendar")
        }
    }

    private func dayStatus(_ state: PeriodState, isToday: Bool) -> String {
        switch state {
        case .posted(let stamp): return stamp.localizedCapitalized
        case .unposted: return isToday ? "Open" : "Awaiting posting"
        }
    }

    private func datePage(title: String, subtitle: String, volume: String, receiptDay: Int64?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 30, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.callout).foregroundStyle(dim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(volume).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Posted byte volume").font(.caption).foregroundStyle(dim)
                }
                if let receiptDay {
                    Button {
                        openWindow(id: ReceiptWindow.id, value: receiptDay)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("View receipt", systemImage: "doc.text")
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()
            if let dateModule {
                moduleNavigation(dateModule)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let dateModule {
                        LedgerModuleView(vm: vm, module: dateModule)
                    } else {
                        moduleOverview
                        if vm.granularity.isAggregate, let story = vm.selectedPeriodStory {
                            daysInPeriod(story.days)
                        }
                    }
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .id(dateModule)
        }
    }

    private func moduleNavigation(_ module: LedgerModule) -> some View {
        HStack {
            Button {
                dateModule = nil
            } label: {
                Label("Overview", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                historyModule = module
                let day = vm.granularity == .day ? vm.selectedDay : vm.selectedGroupID
                historyPreferences.ending = day.flatMap { epoch in
                    epoch < vm.todayEpoch ? Date(timeIntervalSince1970: TimeInterval(epoch)) : nil
                }
                mode = .metric
            } label: {
                Label("View history", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.plain)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(LatticePalette.chassis(scheme).opacity(0.55))
    }

    private var moduleOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Overview")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if vm.granularity == .day, let composite = vm.selectedComposite {
                    Text("Composite \(composite.chipValue)")
                        .font(.caption)
                        .foregroundStyle(dim)
                        .help(composite.receiptLine)
                }
            }
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(LedgerModule.allCases) { module in
                    Divider()
                    moduleRow(module)
                }
                Divider()
            }
        }
    }

    private func moduleRow(_ module: LedgerModule) -> some View {
        let total = module.metrics[0]
        let value = total.value(in: vm.selectedTotals).map(total.formatted)
        return Button {
            dateModule = module
        } label: {
            HStack(spacing: 14) {
                module.icon(scheme, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.rawValue).font(.body.weight(.semibold))
                    Text(module.summaryLabel).font(.callout).foregroundStyle(dim)
                }
                Spacer()
                if let value {
                    Text(value).font(.callout.weight(.medium)).monospacedDigit()
                        .accessibilityLabel("\(total.label), \(value)")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dim)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func daysInPeriod(_ days: [PeriodDay]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recorded days").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(days) { day in
                    Button(DayLabel.short(dayEpoch: day.dayEpoch)) { openDay(day.dayEpoch, module: nil) }
                        .frame(maxWidth: .infinity)
                        .help(DayLabel.full(dayEpoch: day.dayEpoch))
                }
            }
        }
    }

    private func openDay(_ day: Int64, module: LedgerModule?) {
        vm.jumpToDay(day)
        dateModule = module
        mode = .date
    }

    private var trialBalance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All-time trial balance").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Account")
                    Text("Debit").gridColumnAlignment(.trailing)
                    Text("Credit").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(dim)
                Divider()
                ForEach(vm.trialBalance) { row in
                    GridRow {
                        Text(row.label).padding(.leading, row.isSubline ? 10 : 0)
                        Text(row.debit).foregroundStyle(LatticePalette.debit(scheme))
                        Text(row.credit.isEmpty ? "—" : row.credit)
                            .foregroundStyle(row.credit.isEmpty ? dim : LatticePalette.credit(scheme))
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
        .padding(18)
    }
}

extension LedgerModule {
    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .traffic: return LatticePalette.teal(scheme)
        case .storage: return LatticePalette.violet(scheme)
        case .cognition: return LatticePalette.amber(scheme)
        case .mechanics: return LatticePalette.coral(scheme)
        case .exposure: return LatticePalette.green(scheme)
        case .other: return LatticePalette.dim(scheme)
        }
    }

    private var symbol: String {
        switch self {
        case .traffic: return "arrow.up.arrow.down"
        case .storage: return "internaldrive"
        case .cognition: return "brain"
        case .mechanics: return "keyboard"
        case .exposure: return "display"
        case .other: return "waveform.path"
        }
    }

    var summaryLabel: String {
        switch self {
        case .traffic: return "Network traffic and connections"
        case .storage: return "Disk reads and writes"
        case .cognition: return "AI tokens, models, sessions and cost"
        case .mechanics: return "Keystrokes, clicks, scrolling and mouse travel"
        case .exposure: return "Attentive time, sessions and focused apps"
        case .other: return "Energy, files, terminal commands and sensors"
        }
    }

    func icon(_ scheme: ColorScheme, size: CGFloat = 25) -> some View {
        let color = color(scheme)
        return Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}
