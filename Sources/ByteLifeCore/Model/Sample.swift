import Foundation

/// An already-reduced additive delta emitted by a collector. The store only accumulates these.
public struct Sample: Equatable, Sendable {
    public let kind: MetricKind
    public let value: Int64
    public let timestamp: Date

    public init(kind: MetricKind, value: Int64, timestamp: Date) {
        self.kind = kind
        self.value = value
        self.timestamp = timestamp
    }

    public var family: MetricFamily { kind.family }
}
