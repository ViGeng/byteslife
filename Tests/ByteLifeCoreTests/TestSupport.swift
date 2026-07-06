import Foundation
@testable import ByteLifeCore

/// Returns a scripted value per call, clamping to the last entry once exhausted. Drives collectors
/// with deterministic reader output in place of the live system readers.
final class ScriptedReader<Element> {
    private let values: [Element]
    private var index = 0

    init(_ values: [Element]) {
        precondition(!values.isEmpty, "ScriptedReader needs at least one value")
        self.values = values
    }

    func next() -> Element {
        let value = values[Swift.min(index, values.count - 1)]
        index += 1
        return value
    }
}

enum TempStore {
    /// A fresh on-disk store in a unique temp directory, returned with that directory for cleanup.
    static func make() throws -> (store: SampleStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ByteLifeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SampleStore(path: directory.appendingPathComponent("t.sqlite").path)
        return (store, directory)
    }
}

/// A deterministic timestamp anchored to local midnight so samples bucket predictably.
func fixedTimestamp(minute: Int = 10) -> Date {
    Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minute * 60))
}

/// A minimal in-memory `CounterStore` whose `record` can be toggled to throw, used to prove that a
/// counter collector advances its baselines only after a successful transactional write.
final class SpyCounterStore: CounterStore {
    struct WriteFailed: Error {}

    var shouldFail = false
    private(set) var recorded: [Sample] = []
    private(set) var lastRecorded: [Sample] = []
    private var meta: [String: Int64] = [:]

    func record(_ samples: [Sample], settingMeta meta: [String: Int64]) throws {
        // Mirror the store's all-or-nothing contract: on failure neither samples nor meta commit.
        if shouldFail { throw WriteFailed() }
        recorded.append(contentsOf: samples)
        lastRecorded = samples
        for (key, value) in meta { self.meta[key] = value }
    }

    func metaInt(_ key: String) throws -> Int64? { meta[key] }
}
