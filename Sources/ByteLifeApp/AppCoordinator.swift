import Foundation
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
    /// Closes the day's books, composing and posting the immutable receipt. All the real work lives in
    /// ByteLifeCore; the coordinator only supplies the machine name and the live collector states.
    let reconciler: Reconciler

    /// The machine the books belong to, printed on every receipt header.
    let machineName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

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
        auxiliaryRegistry = CollectorRegistry(collectors: [energy, focus, files, hosts])

        reconciler = Reconciler(store: store)
        registry.startAll()
        auxiliaryRegistry.startAll()
    }

    /// Closes today's books, posting the receipt exactly once. Returns the stored reconciliation, or
    /// nil when the day was already closed or storage failed. The day sheet re-reads the store after.
    @discardableResult
    func reconcileToday() -> Reconciliation? {
        reconcile(dayEpoch: DayBucket.dayEpoch(for: Date()))
    }

    /// Closes an arbitrary accounting day, posting its receipt exactly once. Today closes against the
    /// live collector states (BALANCED or FLAGGED); a past day closes in arrears, because availability
    /// for the period was not retained and today's states would stamp it misleadingly. Posts
    /// `.byteLifeDayPosted` on success so any open ledger surface reloads. Returns the stored
    /// reconciliation, or nil when the day was already closed or storage failed.
    @discardableResult
    func reconcile(dayEpoch: Int64) -> Reconciliation? {
        let inArrears = dayEpoch != DayBucket.dayEpoch(for: Date())
        let posted = try? reconciler.reconcile(
            dayEpoch: dayEpoch,
            availability: registry.availabilitySnapshot(),
            machineName: machineName,
            closedInArrears: inArrears
        )
        if posted != nil {
            NotificationCenter.default.post(name: .byteLifeDayPosted, object: nil)
        }
        return posted
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
