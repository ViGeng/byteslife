import Foundation
import Combine
import ByteLifeCore

@MainActor
final class GeneralLedgerViewModel: ObservableObject {
    /// The sidebar granularity: single days, ISO weeks, or local-calendar months. Day keeps the original
    /// day dashboard; the two aggregate granularities show the period story.
    @Published private(set) var granularity: PeriodGranularity = .day
    /// The recorded days, newest first, each with its stamp state (the Day-granularity sidebar rows).
    @Published private(set) var periods: [LedgerPeriod] = []
    /// The aggregate period rows for the Week and Month granularities, newest first.
    @Published private(set) var periodGroups: [PeriodGroup] = []
    /// The all-history figures shown in the trial balance.
    @Published private(set) var trialBalance: [TrialBalanceRow] = []
    /// The day whose dashboard the main pane shows in Day granularity.
    @Published private(set) var selectedDay: Int64?
    /// The selected aggregate period, keyed by its newest member epoch, in Week and Month granularity.
    @Published private(set) var selectedGroupID: Int64?
    /// The selected day's hourly series and ledger figures.
    @Published private(set) var selectedStory: DayStory?
    /// The selected aggregate period's daily series and ledger figures.
    @Published private(set) var selectedPeriodStory: PeriodStory?
    @Published private(set) var selectedTotals: [MetricKind: Int64] = [:]
    /// The selected day's (or aggregate period's) accessory accounts: energy, focus, files, hosts, and the
    /// session/unlock memos. Day granularity carries the energy hourly bars; aggregates are figure-only.
    @Published private(set) var selectedAuxiliary: AuxiliaryStory?
    /// The selected day's (or aggregate period's) COGNITION breakdown: top models with token bars and, for
    /// a single day, the session memo. Aggregates sum model totals across days and carry no memo. Both
    /// carry the notional cost at bundled list prices (a day prices its own rows; an aggregate combines
    /// the member days' daily summaries).
    @Published private(set) var selectedCognition: CognitionBreakdown?
    /// The selected day's BYTELIFE COMPOSITE against its trailing 28 recorded days, shaped from the cached
    /// per-day rollups with no fresh store query. Nil for aggregate periods: the Composite is a day figure.
    @Published private(set) var selectedComposite: Composite?
    /// The selected day's (or aggregate period's) SENSORS deck: the muted curve charts (single days only)
    /// and the sensor count memos. Aggregates sum the counts across days and carry no curves.
    @Published private(set) var selectedSensors: SensorStory?

    /// Today's epoch, so the header can distinguish the still-open today from a posted past day.
    /// Computed live: the window can sit open across midnight, and the auto-close reload must see the
    /// new accounting day rather than the one the window opened on.
    var todayEpoch: Int64 { DayBucket.dayEpoch(for: Date()) }
    private let coordinator: AppCoordinator
    private var postObserver: NSObjectProtocol?

    /// The recorded days, rollups and stamps used by the date list and metric history.
    private var days: [Int64] = []
    @Published private var totalsByDay: [Int64: [MetricKind: Int64]] = [:]
    private var stampsByDay: [Int64: String] = [:]
    /// Per-day foreground time by app and distinct-host counts for aggregate periods.
    private var focusByDay: [Int64: [String: Int64]] = [:]
    private var hostsByDay: [Int64: Int] = [:]

    var store: SampleStore { coordinator.store }
    var earliestDay: Date? { days.last.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    func history(for metric: LedgerHistoryMetric, dayCount: Int, ending end: Date) -> LedgerHistory {
        LedgerHistory(metric: metric, dayCount: dayCount, ending: end, totalsByDay: totalsByDay)
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
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

    /// Refreshes the date sidebar, selected date details, metric history and trial balance.
    func reload() {
        reloadHistory()
        stampsByDay = (try? store.reconciledStamps()) ?? [:]
        focusByDay = (try? store.focus(forDayEpochs: days)) ?? [:]
        hostsByDay = (try? store.distinctHosts(forDayEpochs: days)) ?? [:]
        periods = LedgerPeriod.list(daysWithData: days + [todayEpoch], stampsByDay: stampsByDay)
        trialBalance = TrialBalance.rows(totals: (try? store.trialBalance()) ?? [:])
        rebuildGroups()

        if granularity == .day {
            if selectedDay == nil || !periods.contains(where: { $0.dayEpoch == selectedDay }) {
                selectedDay = todayEpoch
            }
            loadDayDetail()
        } else {
            if selectedGroupID == nil || !periodGroups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = periodGroups.first?.id
            }
            loadPeriodDetail()
        }
    }

    func reloadHistory() {
        days = (try? store.dayEpochsWithData()) ?? []
        totalsByDay = (try? store.totals(forDayEpochs: days)) ?? [:]
    }

    /// Switches granularity and re-selects. Day keeps or defaults its day selection; an aggregate carries
    /// the current day into the period that contains it when possible, else selects the newest period.
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
                selectedDay = todayEpoch
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

    /// Rebuilds the aggregate rows from the cached rollups for the current granularity. Day granularity
    /// uses the `periods` list, so it clears the group rows.
    private func rebuildGroups() {
        periodGroups = granularity.isAggregate
            ? PeriodGrouping.groups(daysWithData: days, granularity: granularity,
                                    totalsByDay: totalsByDay, stampsByDay: stampsByDay)
            : []
    }

    /// Builds the selected day's module charts and details from its totals and series.
    private func loadDayDetail() {
        guard let day = selectedDay else {
            selectedStory = nil
            selectedTotals = [:]
            selectedAuxiliary = nil
            selectedCognition = nil
            selectedSensors = nil
            selectedComposite = nil
            return
        }
        let totals = (try? store.totals(forDayEpoch: day)) ?? [:]
        selectedTotals = totals
        let hourly = (try? store.hourlySeries(
            kinds: DayStory.hourlyKinds + [.energyMilliwattHours], dayEpoch: day
        )) ?? [:]
        // Typing cadence comes from the selected day's minute buckets.
        let cadence = TypingCadence.from(
            minuteKeystrokes: (try? store.dayMinuteSeries(kind: .inputKeystrokes, dayEpoch: day)) ?? []
        )
        selectedStory = DayStory.build(dayEpoch: day, totals: totals, hourly: hourly, cadence: cadence)

        // The day's Composite against its own history, from the cached rollups (Composite.build ignores
        // days at or after the target, so handing the whole map in is safe).
        selectedComposite = Composite.build(dayEpoch: day, todayTotals: totals, history: totalsByDay)

        let focus = (try? store.topFocus(dayEpoch: day, limit: 5)) ?? []
        let hosts = try? store.distinctHosts(dayEpoch: day)
        selectedAuxiliary = AuxiliaryStory.build(
            totals: totals, focus: focus, distinctHosts: hosts, energyHourly: hourly[.energyMilliwattHours] ?? []
        )

        // The COGNITION card's fine-grained view: the day's per-model token totals, its session stats,
        // and the notional cost of the day's rows at bundled list prices.
        let modelTotals = (try? store.aiModelTotals(dayEpoch: day)) ?? []
        let sessionStats = (try? store.aiSessionStats(dayEpoch: day)) ?? AISessionStats(count: 0, averageLength: 0, longestLength: 0)
        selectedCognition = CognitionBreakdown.build(
            modelTotals: modelTotals, sessionStats: sessionStats,
            cost: PriceCard.bundled.cost(of: modelTotals)
        )

        // Sensor details: the five per-minute gauge curves for the day and the count memos from the
        // totals and the read-through meta facts (thermal changes, charging sessions, lifetime cycles).
        var series: [String: [Int64?]] = [:]
        for entry in SensorStory.curveGauges {
            series[entry.gauge] = (try? store.gaugeSeries(gauge: entry.gauge, dayEpoch: day)) ?? []
        }
        selectedSensors = SensorStory.build(
            totals: totals,
            thermalStateChanges: (try? store.metaInt(ThermalCollector.thermalChangesKey(dayEpoch: day))) ?? 0,
            chargingSessions: (try? store.metaInt(BatteryCollector.chargingSessionsKey(dayEpoch: day))) ?? 0,
            batteryCycleCount: try? store.metaInt(BatteryCollector.cycleCountKey),
            gaugeSeries: series
        )
    }

    /// Uses cached per-day rollups for the period charts and loads its model and sensor details.
    private func loadPeriodDetail() {
        guard let id = selectedGroupID,
              let group = periodGroups.first(where: { $0.id == id }) else {
            selectedPeriodStory = nil
            selectedTotals = [:]
            selectedAuxiliary = nil
            selectedCognition = nil
            selectedSensors = nil
            selectedComposite = nil
            return
        }
        // The Composite is a day figure; an aggregate period carries none.
        selectedComposite = nil
        // The period's model rows in one batched query; pricing the summed rows equals combining the
        // daily figures (costs are linear in the token counts), so no per-day cost queries are needed.
        let modelTotals = (try? store.aiModelTotals(dayEpochs: group.dayEpochs)) ?? []
        let periodCost = modelTotals.isEmpty ? nil : PriceCard.bundled.cost(of: modelTotals)
        selectedPeriodStory = PeriodStory.build(
            label: group.label,
            dayEpochs: group.dayEpochs,
            totalsByDay: totalsByDay,
            stampsByDay: stampsByDay,
            aiCost: periodCost
        )

        // The aggregate accessory accounts: sum the accessory totals and the distinct-host counts across
        // member days, and merge the per-day focus rows into one period-wide top list. Figure-only (no
        // hourly bars), all from the cached per-day maps with no fresh store query.
        var summed: [MetricKind: Int64] = [:]
        var mergedFocus: [String: Int64] = [:]
        var hostsTotal = 0
        // The sensor counts held in per-day meta keys, summed across the period.
        var thermalTotal: Int64 = 0
        var chargingTotal: Int64 = 0
        for day in group.dayEpochs {
            for (kind, value) in totalsByDay[day] ?? [:] { summed[kind, default: 0] += value }
            for (bundle, seconds) in focusByDay[day] ?? [:] { mergedFocus[bundle, default: 0] += seconds }
            hostsTotal += hostsByDay[day] ?? 0
            thermalTotal += (try? store.metaInt(ThermalCollector.thermalChangesKey(dayEpoch: day))) ?? 0
            chargingTotal += (try? store.metaInt(BatteryCollector.chargingSessionsKey(dayEpoch: day))) ?? 0
        }
        selectedTotals = summed
        selectedAuxiliary = AuxiliaryStory.build(
            totals: summed,
            focus: mergedFocus.map { (bundleId: $0.key, seconds: $0.value) },
            distinctHosts: hostsTotal
        )

        // The aggregate COGNITION breakdown sums per-model totals across days; sessions are a day figure,
        // so an aggregate carries no session memo. The cost is the same summary the period story carries.
        selectedCognition = CognitionBreakdown.build(
            modelTotals: modelTotals, sessionStats: nil,
            cost: periodCost
        )

        // The aggregate SENSORS deck: the summed count memos and no curves. The cycle count is a lifetime
        // fact read from its single read-through key.
        selectedSensors = SensorStory.build(
            totals: summed,
            thermalStateChanges: thermalTotal,
            chargingSessions: chargingTotal,
            batteryCycleCount: try? store.metaInt(BatteryCollector.cycleCountKey)
        )
    }
}
