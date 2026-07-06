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
    /// The five accounts, their columns, the running balance, and whether today is posted.
    @Published private(set) var daySheet: DaySheet
    /// Today's posted byte volume, shown next to the glyph in the menubar itself.
    @Published private(set) var menubarBalance: String
    /// Today's stored receipt once the day is closed, so the panel can render the immutable strip on
    /// posting and again whenever the user reopens it. Nil while the day is still open.
    @Published private(set) var todaysReceipt: Reconciliation?
    /// Whether ByteLife is currently registered to launch at login.
    @Published private(set) var launchAtLoginEnabled: Bool
    /// False once a register/unregister attempt failed (typically under `swift run`), so the footer can
    /// disclose that the toggle is unavailable rather than silently doing nothing.
    @Published private(set) var launchAtLoginAvailable: Bool = true

    private static let openInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 30

    private let coordinator: AppCoordinator
    private var timer: Timer?
    private var panelVisible = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let initial = DaySheet.build(totals: [:], availabilityByFamily: [:], reconciliation: nil)
        self.daySheet = initial
        self.menubarBalance = initial.postedByteVolume
        self.todaysReceipt = nil
        self.launchAtLoginEnabled = coordinator.isLaunchAtLoginEnabled
        refresh()
        startTimer(interval: Self.idleInterval)
    }

    deinit { timer?.invalidate() }

    /// The panel opened: fetch fresh figures immediately (animated, so stale values roll up to
    /// current), re-read the login-item status, and switch to the fast cadence for live ticking.
    func panelDidAppear() {
        panelVisible = true
        launchAtLoginEnabled = coordinator.isLaunchAtLoginEnabled
        refresh()
        startTimer(interval: Self.openInterval)
    }

    /// The panel closed: drop back to the slow cadence that only keeps the menubar balance fresh.
    func panelDidDisappear() {
        panelVisible = false
        startTimer(interval: Self.idleInterval)
    }

    /// Raises the Input Monitoring prompt. The panel calls this from the needs-permission affordance.
    func requestInputPermission() {
        coordinator.inputCollector.requestPermission()
    }

    /// Closes today's books, then refreshes so the panel flips to its posted state and shows the stamp.
    /// Returns whether a receipt is now on file (freshly posted or already closed), so the panel can
    /// present the strip.
    @discardableResult
    func reconcileToday() -> Bool {
        coordinator.reconcileToday()
        refresh()
        return todaysReceipt != nil
    }

    /// Toggles the login item and reflects the outcome, disclosing unavailability when the OS refuses.
    func toggleLaunchAtLogin() {
        let succeeded = coordinator.setLaunchAtLogin(!launchAtLoginEnabled)
        launchAtLoginAvailable = succeeded
        launchAtLoginEnabled = coordinator.isLaunchAtLoginEnabled
    }

    private func startTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // .common so polling keeps running while the menubar panel tracks a mouse or menu interaction.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let dayEpoch = DayBucket.dayEpoch(for: Date())
        let totals = (try? coordinator.store.totals(forDayEpoch: dayEpoch)) ?? [:]
        let reconciliation = (try? coordinator.store.reconciliation(forDayEpoch: dayEpoch)) ?? nil

        var availabilityByFamily: [MetricFamily: Availability] = [:]
        for entry in coordinator.registry.availabilitySnapshot() {
            availabilityByFamily[entry.family] = entry.availability
        }

        let sheet = DaySheet.build(
            totals: totals,
            availabilityByFamily: availabilityByFamily,
            reconciliation: reconciliation
        )

        let apply = {
            self.daySheet = sheet
            self.menubarBalance = sheet.postedByteVolume
            self.todaysReceipt = reconciliation
        }
        if panelVisible {
            // Figures roll to their new values via the views' numeric content transitions.
            withAnimation(.easeOut(duration: 0.5), apply)
        } else {
            apply()
        }
    }
}
