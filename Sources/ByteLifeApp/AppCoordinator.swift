import Foundation
import ByteLifeCore

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
    /// Retained so the UI can raise the Input Monitoring prompt from an explicit user action.
    let inputCollector: InputCollector

    private init() {
        let dbPath = Self.databaseURL().path
        do {
            store = try SampleStore(path: dbPath)
        } catch {
            // Storage is the app's reason to exist; without it there is nothing to show or record.
            fatalError("ByteLife could not open its database at \(dbPath): \(error)")
        }

        let ai = AICollector(store: store)
        let network = NetworkCollector(store: store)
        let disk = DiskCollector(store: store)
        let screen = ScreenCollector(store: store)
        let input = InputCollector(store: store)
        inputCollector = input

        // Registration order is the UI's row order via the availability snapshot; it matches
        // MetricFamily.allCases so the view model and the registry agree.
        registry = CollectorRegistry(collectors: [ai, network, disk, screen, input])
        registry.startAll()
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
