import Foundation
import Combine
import SwiftUI
import ByteLifeCore

/// Drives the Ledger menubar panel. A timer polls today's totals and the registry's availability
/// snapshot, reshapes them into a `DaySheet` via the core domain layer, and republishes it along with
/// the menubar running-balance figure and the launch-at-login state. Kept on the main actor and
/// poll-driven because it feeds SwiftUI directly; all figure and column logic lives in ByteLifeCore's
/// `DaySheet`, so this stays a thin publisher.
///
/// The poll runs at two cadences: a slow idle tick that only keeps the menubar balance fresh while the
/// panel is closed, and a fast tick while the panel is open so the figures climb live. Opening the
/// panel refreshes immediately, and refreshes while the panel is visible are wrapped in an animation so
/// the monospaced figures roll to their new values (the split-flap tick the concept sheet asks for).
@MainActor
final class DashboardViewModel: ObservableObject {
    /// The five accounts, their columns, and the running balance. The current day is always open now
    /// that the books keep themselves, so the sheet never carries a posted state.
    @Published private(set) var daySheet: DaySheet
    /// Today's posted byte volume, shown next to the glyph in the menubar itself.
    @Published private(set) var menubarBalance: String
    /// The live Meter Bridge: five rendered channels with rates, history bars, and peak-holds. Rebuilt on
    /// every fast tick while the panel is open; left untouched on idle ticks (the label needs no meter).
    @Published private(set) var meterBridge: MeterBridge
    /// The last few inter-poll combined byte deltas (traffic + storage), newest first, for the header's
    /// hex ticker. Real snapshot deltas only — cleared on reopen so a close-gap aggregate never prints.
    @Published private(set) var tickerDeltas: [Int64] = []
    /// The ALSO ON THE BOOKS strip: the day's accessory figures (energy, top app, files, hosts, unlocks)
    /// as compact chips. Rebuilt on the same ticks as the day sheet from single-day indexed lookups.
    @Published private(set) var auxiliaryStrip: AuxiliaryStrip = AuxiliaryStrip(chips: [])
    /// Today's BYTELIFE COMPOSITE for the panel-header chip, rebuilt on the visible ticks from the totals
    /// already fetched plus the cached trailing history. Starts (and honestly reads) as collecting until
    /// the baseline holds enough recorded days.
    @Published private(set) var composite: Composite = .collecting(recordedDays: 0)
    /// Whether ByteLife is currently registered to launch at login.
    @Published private(set) var launchAtLoginEnabled: Bool
    /// False once a register/unregister attempt failed (typically under `swift run`), so the footer can
    /// disclose that the toggle is unavailable rather than silently doing nothing.
    @Published private(set) var launchAtLoginAvailable: Bool = true
    /// Set once a Grant attempt returned with the grant still absent (macOS suppressed the repeat prompt).
    /// The MECHANICS calibrate menu then reveals the "Reset permission state…" affordance. Cleared once a
    /// reset re-raises the prompt.
    @Published private(set) var inputPromptSuppressed = false

    private static let openInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 30
    /// How stale the last snapshot may be and still be reused warm on reopen. Within this window the slow
    /// background tick has kept the snapshot and EMA current, so the LIVE chip and rates are right on the
    /// first frame; beyond it (a fresh launch, a long sleep) the state is a phantom and resets.
    private static let warmMaxAge: TimeInterval = 45

    private let coordinator: AppCoordinator
    private var timer: Timer?
    private var panelVisible = false
    /// Live mode, mirrored from the view's `@AppStorage("liveMode")`. The view owns it (the LIVE button
    /// and its persistence) and hands the current value in on open and on every toggle; the view model
    /// reads it only to choose the timer cadence.
    private var liveMode = true
    /// The prior totals reading, so the meter can derive a live rate from the inter-poll delta. Every
    /// tick advances it now — the fast open ticks and the slow background tick alike — so the panel opens
    /// warm against a recent reading instead of cold-starting on every reopen.
    private var previousSnapshot: MeterSnapshot?
    /// The carried smoothing and peak-hold state threaded between meter builds. Resets on relaunch.
    private var meterState: MeterState = .initial
    /// The per-channel chart windows, mirrored from the view's `@AppStorage` menus. Primed from the same
    /// persisted keys in `init` so the very first open fetches and buckets at the right depth, then kept
    /// current by `setWindows` on every menu change. They drive both the fetch depth and each channel's
    /// bucketing; a channel absent from the map falls back to 30M in the core build.
    private var channelWindows: [MeterChannelKind: MeterWindow] = [:]
    /// When the auto-close sweep last ran. The sweep rides the existing ticks but is throttled to the
    /// idle cadence, so the panel's 2-second hot path gains no recurring queries.
    private var lastSweepAttempt: Date = .distantPast
    /// The Composite baseline history (up to 28 recorded days strictly before today), cached while the
    /// panel stays open so no new query joins the 2-second hot path. The cache is dropped on every panel
    /// open (not just at rollover): AI transcript backfill and cross-midnight sessions book samples onto
    /// past days after launch, so a day-long cache would freeze a stale or still-collecting baseline. A
    /// failed fetch stays nil so the next tick retries instead of latching an empty history all day.
    private var compositeHistory: (dayEpoch: Int64, history: [Int64: [MetricKind: Int64]])?

    /// Completed minutes of history to fetch each tick: the deepest window any selected chart reads, so
    /// one indexed `minuteSeries` call serves every channel at once. At 24H this is 1440 rows
    /// per kind, still a primary-key range scan over one or two contiguous days.
    private var fetchMinutes: Int {
        channelWindows.values.map(\.totalMinutes).max() ?? MeterWindow.default.totalMinutes
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.channelWindows = ChartWindowStore.channelWindows()
        let initial = DaySheet.build(totals: [:], availabilityByFamily: [:], reconciliation: nil)
        self.daySheet = initial
        self.menubarBalance = initial.postedByteVolume
        self.meterBridge = MeterBridge.build(
            current: MeterSnapshot(totals: [:], timestamp: Date()),
            previous: nil, series: [:], availabilityByFamily: [:], priorState: .initial
        )
        self.launchAtLoginEnabled = coordinator.isLaunchAtLoginEnabled
        refresh(publishMeter: false, animated: false)
        startTimer(interval: Self.idleInterval, publishMeter: false, animated: false)
    }

    deinit { timer?.invalidate() }

    /// The panel opened: paint fresh figures immediately (WITHOUT animation, so the panel appears fully
    /// formed rather than sliding a stale frame up to current), re-read the login-item status, and, in
    /// live mode, switch to the fast cadence for live ticking. The `live` flag comes from the view's
    /// persisted LIVE toggle.
    ///
    /// The state opens warm: when the last snapshot is recent (the slow background tick kept it current),
    /// it is kept so the LIVE chip and rates are correct on the very first frame. Only after a long gap —
    /// a fresh launch or a long sleep, where a carried reading would be a phantom — do the previous
    /// snapshot and the EMA cold-start (peaks persist). The ticker always clears, since its close-gap
    /// aggregate has no meaning across a reopen.
    func panelDidAppear(live: Bool) {
        panelVisible = true
        liveMode = live
        // Refetch the Composite baseline on each open, picking up any backfill onto past days.
        compositeHistory = nil
        launchAtLoginEnabled = coordinator.isLaunchAtLoginEnabled
        if let previous = previousSnapshot, Date().timeIntervalSince(previous.timestamp) > Self.warmMaxAge {
            previousSnapshot = nil
            meterState = meterState.resettingSmoothing()
        }
        tickerDeltas = []
        refresh(publishMeter: true, animated: false)
        if live {
            startTimer(interval: Self.openInterval, publishMeter: true, animated: true)
        } else {
            startTimer(interval: Self.idleInterval, publishMeter: false, animated: false)
        }
    }

    /// The LIVE control toggled while the panel is open. Turning it on starts the fast cadence at once
    /// with an animated refresh; turning it off stops the fast timer and drops back to the slow
    /// background tick, freezing the readouts as of now (the view then dims them, since they are no
    /// longer live). While the panel is closed this only records the value for the next open.
    func setLiveMode(_ live: Bool) {
        liveMode = live
        guard panelVisible else { return }
        if live {
            refresh(publishMeter: true, animated: true)
            startTimer(interval: Self.openInterval, publishMeter: true, animated: true)
        } else {
            startTimer(interval: Self.idleInterval, publishMeter: false, animated: false)
        }
    }

    /// A chart-window menu changed. The view hands in the full current selection; the view model stores
    /// it so the next fetch reaches the right depth and each channel buckets at its window. While the
    /// panel is open it refreshes at once (animated) so the chart re-buckets immediately; closed, it only
    /// records the choice for the next open. No new snapshot is taken, so rates and peaks are untouched —
    /// only the history bars re-shape.
    func setWindows(_ windows: [MeterChannelKind: MeterWindow]) {
        channelWindows = windows
        guard panelVisible else { return }
        refresh(publishMeter: true, animated: true)
    }

    /// The panel closed: drop back to the slow cadence that keeps the menubar balance fresh and carries
    /// the warm state forward.
    func panelDidDisappear() {
        panelVisible = false
        startTimer(interval: Self.idleInterval, publishMeter: false, animated: false)
    }

    /// The home for blocking permission work: the request is an XPC round trip to tccd that can take
    /// seconds, and the reset additionally spawns tccutil and waits for it. Running either inline
    /// beachballed the panel on 0.8.0, and a cooperative-pool thread is the wrong place to park a
    /// blocking syscall. A SERIAL queue also means a double-clicked affordance runs its flows one after
    /// the other instead of racing two prompts.
    private static let permissionQueue = DispatchQueue(label: "life.byte.permission", qos: .userInitiated)

    /// Raises the Input Monitoring prompt. The panel calls this from the needs-permission affordance. When
    /// the request returns with the grant still absent — macOS suppresses the repeat prompt after the
    /// first decision — this sets `inputPromptSuppressed` so the panel reveals the reset affordance. The
    /// blocking request runs on `permissionQueue`; only the published outcome hops back to the main actor.
    func requestInputPermission() {
        let collector = coordinator.inputCollector
        Self.permissionQueue.async { [weak self] in
            let outcome = collector.requestPermission()
            Task { @MainActor [weak self] in
                self?.inputPromptSuppressed = outcome == .promptSuppressed
            }
        }
    }

    /// Runs the TCC reset recovery from the panel. Returns tccutil's nonzero exit code on failure, so the
    /// panel can surface an honest alert, or nil on success, where the prompt has been re-raised and the
    /// suppressed flag clears. The blocking flow (tccutil, then the re-raised prompt request) runs on
    /// `permissionQueue`; the await suspends the main actor without blocking it.
    func resetInputPermission() async -> Int32? {
        let collector = coordinator.inputCollector
        let outcome = await withCheckedContinuation { continuation in
            Self.permissionQueue.async {
                continuation.resume(returning: collector.resetPermissionState())
            }
        }
        switch outcome {
        case .reprompted:
            inputPromptSuppressed = false
            return nil
        case .failed(let code):
            return code
        }
    }

    /// Toggles the login item and reflects the outcome, disclosing unavailability when the OS refuses.
    func toggleLaunchAtLogin() {
        let succeeded = coordinator.setLaunchAtLogin(!launchAtLoginEnabled)
        launchAtLoginAvailable = succeeded
        launchAtLoginEnabled = coordinator.isLaunchAtLoginEnabled
    }

    /// Installs the polling timer at the given cadence. `publishMeter` and `animated` are the flags each
    /// tick carries into `refresh`: the fast open timer publishes the rebuilt meter and rolls the digits;
    /// the slow background timer only freshens the label and carries the warm state cheaply.
    private func startTimer(interval: TimeInterval, publishMeter: Bool, animated: Bool) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(publishMeter: publishMeter, animated: animated) }
        }
        // .common so polling keeps running while the menubar panel tracks a mouse or menu interaction.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One poll. It always reads today's totals, reshapes the day sheet, and carries the meter state
    /// forward. When `publishMeter` is set (the open single refresh and the fast open ticks) it also
    /// fetches the minute series, rebuilds the meter, and publishes it with the ticker; otherwise (the
    /// slow background tick) it skips the series fetch and republish, freshening only the label. When
    /// `animated` is set the published figures roll to their new values via numeric content transitions.
    private func refresh(publishMeter: Bool, animated: Bool) {
        let now = Date()
        // The self-keeping books ride the existing ticks, throttled to the idle cadence so the fast
        // open ticks add no recurring queries. The coordinator runs the sweep on its own serial
        // background queue, so neither this call in init (the one-time upgrade backfill can close
        // many days) nor a tick ever blocks the main thread. A sweep that hits a storage error simply
        // runs again on a later tick; the coordinator notifies open ledger surfaces when anything
        // posted.
        if now.timeIntervalSince(lastSweepAttempt) >= Self.idleInterval {
            lastSweepAttempt = now
            coordinator.closeOverdueDays(now: now)
        }
        let dayEpoch = DayBucket.dayEpoch(for: now)
        let totals = (try? coordinator.store.totals(forDayEpoch: dayEpoch)) ?? [:]

        var availabilityByFamily: [MetricFamily: Availability] = [:]
        for entry in coordinator.registry.availabilitySnapshot() {
            availabilityByFamily[entry.family] = entry.availability
        }

        // The current accounting day is by definition open (the auto-closer only ever closes days
        // already ended), so the sheet builds with no reconciliation row.
        let sheet = DaySheet.build(
            totals: totals,
            availabilityByFamily: availabilityByFamily,
            reconciliation: nil,
            aiSources: coordinator.aiCollector.sourceStatuses()
        )

        // The ALSO ON THE BOOKS strip: single-day indexed lookups for the top app and the distinct-host
        // count, built only while the panel is visible (nobody reads the strip when it is closed). Each
        // chip's presence follows its sensor's availability, so an off sensor reads a dim dash while a
        // running-but-idle sensor reads a genuine 0. Unlocks come from the screen collector in the main
        // registry; energy, focus, files, and hosts are the accessory sensors.
        var strip: AuxiliaryStrip?
        var compositeToday: Composite?
        if panelVisible {
            // The COMPOSITE chip: today's totals (already in hand) against the cached trailing history,
            // fetched once per panel-open session (and again at rollover). A failed read leaves the
            // cache nil, so the chip shows collecting for one tick and the next tick retries.
            if compositeHistory?.dayEpoch != dayEpoch {
                compositeHistory = nil
                if let recorded = try? coordinator.store.dayEpochsWithData() {
                    let days = Array(recorded.filter { $0 < dayEpoch }.prefix(Composite.baselineWindow))
                    if let history = try? coordinator.store.totals(forDayEpochs: days) {
                        compositeHistory = (dayEpoch, history)
                    }
                }
            }
            compositeToday = Composite.build(
                dayEpoch: dayEpoch, todayTotals: totals, history: compositeHistory?.history ?? [:]
            )

            let topFocus = (try? coordinator.store.topFocus(dayEpoch: dayEpoch, limit: 1))?.first
            let aux = coordinator.auxiliaryRegistry
            let hostsRunning = aux.availability(forID: "hosts") == .running
            let distinctHosts = hostsRunning
                ? (try? coordinator.store.distinctHosts(dayEpoch: dayEpoch)) : nil
            strip = AuxiliaryStrip.build(
                totals: totals,
                topFocus: topFocus,
                distinctHosts: distinctHosts,
                energyRunning: aux.availability(forID: "energy") == .running,
                focusRunning: aux.availability(forID: "focus") == .running,
                filesRunning: aux.availability(forID: "files") == .running,
                unlocksRunning: coordinator.registry.availability(forID: "screen") == .running,
                commandsRunning: aux.availability(forID: "shell") == .running
            )
        }

        let current = MeterSnapshot(totals: totals, timestamp: now)

        // The published meter needs the minute series; the background carry does not, so it builds with
        // an empty series to stay cheap and takes only the resulting state. Either way the snapshot and
        // meter state advance, so the panel stays warm.
        var bridge: MeterBridge?
        var ticker: [Int64]?
        var series: [MetricKind: [Int64]] = [:]
        if publishMeter {
            series = (try? coordinator.store.minuteSeries(
                kinds: MeterBridge.trackedKinds, count: fetchMinutes, endingBefore: now
            )) ?? [:]
            // The hex ticker prints real inter-poll byte deltas (traffic + storage), newest first. It
            // prints only over a short gap, the same honesty gate the peak uses: the first tick after a
            // warm reopen spans the whole closed interval, and that close-gap aggregate must not print.
            if let previous = previousSnapshot,
               now.timeIntervalSince(previous.timestamp) <= MeterBridge.peakMaxElapsed {
                let byteKinds: [MetricKind] = [.networkBytesIn, .networkBytesOut, .diskBytesRead, .diskBytesWritten]
                let delta = byteKinds.reduce(Int64(0)) {
                    $0 + max(0, (current.totals[$1] ?? 0) - (previous.totals[$1] ?? 0))
                }
                ticker = Array(([delta] + tickerDeltas).prefix(4))
            }
        }
        // MECHANICS engraves the re-grant tag instead of the generic UNCALIBRATED when the input
        // collector's stale-tap detector has flagged a grant gone stale under a changed signature.
        let regrantFamilies: Set<MetricFamily> =
            coordinator.inputCollector.tapSuspectStale ? [.input] : []
        let built = MeterBridge.build(
            current: current,
            previous: previousSnapshot,
            series: series,
            availabilityByFamily: availabilityByFamily,
            priorState: meterState,
            regrantFamilies: regrantFamilies,
            windows: channelWindows
        )
        previousSnapshot = current
        meterState = built.state
        if publishMeter { bridge = built }

        let apply = {
            self.daySheet = sheet
            self.menubarBalance = sheet.postedByteVolume
            if let bridge { self.meterBridge = bridge }
            if let ticker { self.tickerDeltas = ticker }
            if let strip { self.auxiliaryStrip = strip }
            if let compositeToday { self.composite = compositeToday }
        }
        if animated {
            // Figures roll to their new values via the views' numeric content transitions.
            withAnimation(.easeOut(duration: 0.5), apply)
        } else {
            apply()
        }
    }
}
