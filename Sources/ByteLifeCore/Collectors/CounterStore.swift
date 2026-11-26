import Foundation

/// The disk counter's store dependency. Tests can inject a failing store to check baseline retries.
protocol CounterStore: AnyObject {
    func record(_ samples: [Sample], settingMeta meta: [String: Int64]) throws
    func metaInt(_ key: String) throws -> Int64?
}

extension SampleStore: CounterStore {}
