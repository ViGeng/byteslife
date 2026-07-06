import Foundation

/// The subset of `SampleStore` the counter collectors (network, disk) depend on. Extracted as a
/// protocol so tests can inject a failing store and prove that a failed commit advances neither the
/// recorded deltas nor the in-memory baselines.
protocol CounterStore: AnyObject {
    func record(_ samples: [Sample], settingMeta meta: [String: Int64]) throws
    func metaInt(_ key: String) throws -> Int64?
}

extension SampleStore: CounterStore {}
