import Foundation
import Combine
import ByteLifeCore

/// One family's line in the panel: its name, a formatted primary value, an optional secondary detail
/// (cache tokens for AI), and its current availability for the badge.
struct FamilyRow: Identifiable {
    let family: MetricFamily
    let value: String
    let detail: String?
    let availability: Availability
    var id: MetricFamily { family }
}

/// Drives the menubar panel. A ~2s timer polls today's totals from the store and the registry's
/// availability snapshot, then republishes one `FamilyRow` per family. Kept on the main actor because
/// it feeds SwiftUI directly.
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var rows: [FamilyRow] = []

    private let coordinator: AppCoordinator
    private var timer: Timer?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // .common so polling keeps running while the menubar panel tracks a mouse or menu interaction.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    /// Raises the Input Monitoring prompt. The panel calls this from the needs-permission affordance.
    func requestInputPermission() {
        coordinator.inputCollector.requestPermission()
    }

    private func refresh() {
        let dayEpoch = DayBucket.dayEpoch(for: Date())
        let totals = (try? coordinator.store.totals(forDayEpoch: dayEpoch)) ?? [:]

        var availabilityByFamily: [MetricFamily: Availability] = [:]
        for entry in coordinator.registry.availabilitySnapshot() {
            availabilityByFamily[entry.family] = entry.availability
        }

        rows = MetricFamily.allCases.map { family in
            FamilyRow(
                family: family,
                value: Self.value(for: family, totals: totals),
                detail: Self.detail(for: family, totals: totals),
                availability: availabilityByFamily[family] ?? .disabled
            )
        }
    }

    private static func value(for family: MetricFamily, totals: [MetricKind: Int64]) -> String {
        func total(_ kind: MetricKind) -> Int64 { totals[kind] ?? 0 }
        switch family {
        case .network:
            return "↓ \(ByteFormatting.bytes(total(.networkBytesIn)))   ↑ \(ByteFormatting.bytes(total(.networkBytesOut)))"
        case .disk:
            return "R \(ByteFormatting.bytes(total(.diskBytesRead)))   W \(ByteFormatting.bytes(total(.diskBytesWritten)))"
        case .ai:
            return "\(ByteFormatting.tokens(total(.aiInputTokens))) in   \(ByteFormatting.tokens(total(.aiOutputTokens))) out"
        case .screen:
            return ByteFormatting.duration(seconds: total(.screenAttentiveSeconds))
        case .input:
            return "\(ByteFormatting.tokens(total(.inputKeystrokes))) keys   \(ByteFormatting.pixelDistance(milliPixels: total(.inputMouseMilliPixels)))"
        }
    }

    private static func detail(for family: MetricFamily, totals: [MetricKind: Int64]) -> String? {
        guard family == .ai else { return nil }
        let created = totals[.aiCacheCreationTokens] ?? 0
        let read = totals[.aiCacheReadTokens] ?? 0
        guard created > 0 || read > 0 else { return nil }
        return "cache \(ByteFormatting.tokens(created)) write / \(ByteFormatting.tokens(read)) read"
    }
}
