import Foundation
import AppKit
import ServiceManagement
import ByteLifeCore

extension Notification.Name {
    /// Posted after a day's books close successfully, so an already-open General Ledger window
    /// reloads instead of showing the day as still open.
    static let byteLifeDayPosted = Notification.Name("ByteLifeDayPosted")
}

/// Owns the app's long-lived model layer: the on-disk store, every collector, and the registry that
/// drives their lifecycle. Built once as a lazy singleton the first time the SwiftUI App reads it,
/// which happens on the main thread during launch.
///
/// This is a thin wiring layer by design. All real logic lives in ByteLifeCore; the coordinator only
/// resolves the storage location, constructs the five collectors against a shared store, registers
/// them, and starts them.
final class AppCoordinator {
    static let shared = AppCoordinator()

    let store: SampleStore
    let registry: CollectorRegistry
    /// The accessory sensors (energy, app focus, files touched, distinct hosts). They live in their own
    /// registry, kept out of the flagship snapshot the reconciler stamps from, so a sensor that is
    /// legitimately absent (energy on a battery-less desktop, hosts when nettop cannot run) never marks a
    /// receipt FLAGGED. The surfaces read their availability from here.
    let auxiliaryRegistry: CollectorRegistry
    /// Retained so the UI can raise the Input Monitoring prompt from an explicit user action.
    let inputCollector: InputCollector
    /// Retained so the Token Account disclosure can read which AI sources are reporting.
    let aiCollector: AICollector
    /// Closes the books, composing and posting immutable receipts. All the real work lives in
    /// ByteLifeCore; the coordinator only supplies the machine name and the live collector states.
    let reconciler: Reconciler

    /// The machine the books belong to, printed on every receipt header.
    let machineName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    /// When the app last became a live witness: launch, then every wake from sleep; `.distantFuture`
    /// while the machine sleeps. The auto-closer stamps a just-ended day from the live snapshot only
    /// when the app was awake since before that day's midnight; a launch or wake that missed the
    /// rollover posts it in arrears instead. The sleep sentinel matters because the sweep timer and
    /// the wake notification race on the main run loop after a wake: a sweep that fires first must
    /// not read a pre-sleep value and live-stamp a midnight the machine slept through.
    private(set) var awakeSince = Date()
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    private init() {
        let dbPath = Self.databaseURL().path
        do {
            store = try SampleStore(path: dbPath)
        } catch {
            // Storage is the app's reason to exist; without it there is nothing to show or record.
            fatalError("ByteLife could not open its database at \(dbPath): \(error)")
        }

        let ai = AICollector(store: store)
        aiCollector = ai
        let network = NetworkCollector(store: store)
        let disk = DiskCollector(store: store)
        let screen = ScreenCollector(store: store)
        let input = InputCollector(store: store)
        inputCollector = input

        // Registration order is the UI's row order via the availability snapshot; it matches
        // MetricFamily.allCases so the view model and the registry agree.
        registry = CollectorRegistry(collectors: [ai, network, disk, screen, input])

        // The accessory sensors. The files collector excludes ByteLife's own data directory, which sits
        // under ~/Library and is therefore already covered by the default ~/Library exclusion.
        let appDataDir = Self.databaseURL().deletingLastPathComponent().path
        let energy = EnergyCollector(store: store)
        let focus = AppFocusCollector(store: store)
        let files = FilesTouchedCollector(store: store, appDataDir: appDataDir)
        let hosts = HostsSeenCollector(store: store)
        let shell = ShellHistoryCollector(store: store)
        // The sensor deck: lid, thermals, battery, ambient light, brightness, wakes/boots, audio, and
        // Bluetooth. Each owns its serial queue and degrades to sourceMissing where its hardware is absent,
        // so a machine without a given sensor never flags a receipt (the auxiliary registry is kept out of
        // the flagship stamp snapshot).
        let lid = LidCollector(store: store)
        let thermal = ThermalCollector(store: store)
        let battery = BatteryCollector(store: store)
        let ambient = AmbientLightCollector(store: store)
        let brightness = BrightnessCollector(store: store)
        let wakes = WakesCollector(store: store)
        let audio = AudioCollector(store: store)
        let bluetooth = BluetoothCollector(store: store)
        auxiliaryRegistry = CollectorRegistry(collectors: [
            energy, focus, files, hosts, shell,
            lid, thermal, battery, ambient, brightness, wakes, audio, bluetooth,
        ])

        reconciler = Reconciler(store: store)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.awakeSince = Date() }
        // Sleep ends the witness before the machine goes down, so no post-wake sweep can ever see a
        // stale pre-sleep value, whatever order the run loop delivers the timer and the wake in.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.awakeSince = .distantFuture }
        // Collector start-up does real I/O — the AI sources stat (and on first run, tail) every recent
        // transcript during discovery — so it must not run on the main thread, where it stalls the
        // app's first frames. Every collector is internally thread-safe and none needs a main run loop
        // (the input tap spins its own dedicated thread), so both registries start in the background.
        // The first panel render reads the collectors' honest initial availability and self-corrects
        // on the next poll.
        let flagship = registry
        let auxiliary = auxiliaryRegistry
        DispatchQueue.global(qos: .utility).async {
            flagship.startAll()
            auxiliary.startAll()
        }
    }

    /// The sweep's serial home, off the main thread: the first sweep after an upgrade backfills every
    /// historical day (a burst of store queries per close) and must not stall the launch frames or the
    /// panel — the 0.8.1 frozen-launch lesson. Serial, so ticks never run overlapping sweeps.
    private static let sweepQueue = DispatchQueue(label: "life.byte.sweep", qos: .utility)

    /// The self-keeping books: closes every recorded day older than the current accounting day that
    /// has no receipt yet, each exactly once. A day whose midnight just passed (inside the grace
    /// window, with the app awake through the rollover) stamps from the flagship snapshot; every
    /// other day posts in arrears. The witness state is captured on the caller's (main) thread and
    /// the sweep runs on `sweepQueue`; `.byteLifeDayPosted` posts back on main when anything closed
    /// so any open ledger surface reloads. A storage error is dropped because the tick calls again.
    func closeOverdueDays(now: Date = Date()) {
        let availability = registry.availabilitySnapshot()
        let awake = awakeSince
        Self.sweepQueue.async { [reconciler, machineName] in
            let posted = (try? reconciler.closeOverdueDays(
                availability: availability,
                machineName: machineName,
                awakeSince: awake,
                now: now
            )) ?? []
            if !posted.isEmpty {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .byteLifeDayPosted, object: nil)
                }
            }
        }
    }

    /// Whether ByteLife is registered to launch at login. Reads the live SMAppService status.
    var isLaunchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters the login item, returning whether the change took. Registration can
    /// fail under `swift run` because the launch item binds to a bundled, signed identity, so the caller
    /// degrades gracefully rather than trapping.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// Application Support/ByteLife/bytelife.sqlite, creating the directory if needed.
    private static func databaseURL() -> URL {
        let fileManager = FileManager.default
        let base: URL
        do {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            fatalError("ByteLife could not locate Application Support: \(error)")
        }
        let directory = base.appendingPathComponent("ByteLife", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("bytelife.sqlite")
    }
}
