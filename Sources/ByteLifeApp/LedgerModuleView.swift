import SwiftUI
import Charts
import ByteLifeCore

struct LedgerModuleView: View {
    @ObservedObject var vm: GeneralLedgerViewModel
    let module: LedgerModule

    @Environment(\.colorScheme) private var scheme

    private var dim: Color { LatticePalette.dim(scheme) }
    private var color: Color { module.color(scheme) }
    private var isDay: Bool { vm.granularity == .day }

    var body: some View {
        let metrics = module.metrics
        let primary = metrics[0]
        let value = primary.value(in: vm.selectedTotals)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                module.icon(scheme, size: 38)
                Text(module.rawValue)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let value {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(primary.formatted(value))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text(primary.label).font(.caption).foregroundStyle(dim)
                    }
                }
            }

            if value != nil, !bars.isEmpty {
                activityChart(bars, metric: primary)
            }

            VStack(spacing: 0) {
                let details = module == .other ? Array(metrics.dropFirst().prefix(2)) : Array(metrics.dropFirst())
                ForEach(details) { metric in
                    let reading = metric.value(in: vm.selectedTotals)
                    figure(metric.label, reading.map(metric.formatted) ?? "—")
                }
                ForEach(memos) { line in
                    figure(line.label, line.value)
                }
                if module == .traffic, let hosts = vm.selectedAuxiliary?.distinctHosts, hosts > 0 {
                    figure(isDay ? "Distinct hosts" : "Distinct hosts (sum of daily counts)",
                           ByteFormatting.grouped(Int64(hosts)))
                }
            }

            switch module {
            case .traffic:
                if isDay, let day = vm.selectedDay {
                    NetworkTrafficView(dayEpoch: day, store: vm.store)
                        .id(day)
                }
            case .cognition:
                if let cognition = vm.selectedCognition {
                    cognitionDetails(cognition)
                }
            case .exposure:
                if let auxiliary = vm.selectedAuxiliary {
                    focusDetails(auxiliary.focusApps)
                }
            case .other:
                if let sensors = vm.selectedSensors {
                    sensorDetails(sensors)
                }
            case .storage, .mechanics:
                EmptyView()
            }
        }
    }

    private var dayAccount: DayStoryCard? {
        vm.selectedStory?.cards.first { $0.kind == module.account }
    }

    private var periodAccount: PeriodStoryCard? {
        vm.selectedPeriodStory?.cards.first { $0.kind == module.account }
    }

    private var bars: [Int64] {
        if module == .other { return isDay ? vm.selectedAuxiliary?.energyHourly ?? [] : [] }
        return isDay ? dayAccount?.hourly ?? [] : periodAccount?.perDay ?? []
    }

    private var memos: [DaySheetLine] {
        let lines = isDay ? dayAccount?.lines : periodAccount?.lines
        return (lines ?? []).filter { $0.side == .memo && $0.label != "Churn" && $0.label != "Cache" }
    }

    private func activityChart(_ values: [Int64], metric: LedgerHistoryMetric) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(isDay ? "By hour" : "By recorded day")
            Chart(values.indices, id: \.self) { index in
                BarMark(x: .value("Time", index), y: .value(metric.label, Double(values[index])))
                    .foregroundStyle(color.opacity(0.85))
                    .accessibilityLabel(axisLabel(index))
                    .accessibilityValue(metric.formatted(values[index]))
            }
            .chartYScale(domain: 0...Double(max(1, values.max() ?? 0)))
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(LatticePalette.hairline(scheme))
                    AxisValueLabel {
                        if let amount = value.as(Double.self), let whole = Int64(exactly: amount.rounded()) {
                            Text(metric.formatted(whole)).font(.caption2).foregroundStyle(dim)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: isDay ? [0, 6, 12, 18] : Array(stride(from: 0, to: values.count, by: max(1, (values.count + 5) / 6)))) {
                    value in
                    AxisValueLabel {
                        if let index = value.as(Int.self) {
                            Text(axisLabel(index)).font(.caption2).foregroundStyle(dim)
                        }
                    }
                }
            }
            .frame(height: 145)
        }
    }

    private func axisLabel(_ index: Int) -> String {
        if isDay { return String(format: "%02d:00", index) }
        guard let days = vm.selectedPeriodStory?.days, days.indices.contains(index) else { return "" }
        return DayLabel.short(dayEpoch: days[index].dayEpoch)
    }

    private func cognitionDetails(_ cognition: CognitionBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if !cognition.models.isEmpty {
                sectionHeading("By model")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Tokens").gridColumnAlignment(.trailing)
                        Text("List-price cost").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dim)
                    Divider()
                    ForEach(cognition.models) { model in
                        GridRow {
                            Text(model.label)
                            Text(model.tokenLabel)
                            Text(model.costLabel ?? "—")
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                }
            }
            if let cost = cognition.costLine {
                figure("Notional cost", cost)
            }
            if let disclosure = cognition.costDisclosure {
                Text(disclosure).font(.caption).foregroundStyle(dim)
            }
            if let memo = cognition.sessionMemo {
                Text(memo).font(.callout).foregroundStyle(dim)
            }
        }
    }

    private func focusDetails(_ apps: [AuxiliaryFocusApp]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading("Top focused apps").padding(.bottom, 8)
            if apps.isEmpty {
                Text("No app focus recorded.")
                    .font(.callout)
                    .foregroundStyle(dim)
            }
            ForEach(apps) { app in
                figure(app.name, app.timeLabel)
            }
        }
    }

    private func sensorDetails(_ sensors: SensorStory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Sensors")
            ForEach(sensors.curves.filter(\.hasData)) { curve in
                sensorChart(curve)
            }
            VStack(spacing: 0) {
                ForEach(sensors.memos) { memo in
                    figure(memo.label.localizedCapitalized, memo.value)
                }
            }
        }
    }

    private struct SensorPoint: Identifiable {
        let segment: Int
        let minute: Int
        let value: Double
        var id: Int { minute }
    }

    private func sensorChart(_ curve: SensorCurve) -> some View {
        var segment = 0
        let points = curve.points.enumerated().compactMap { minute, reading -> SensorPoint? in
            guard let reading else { return nil }
            if minute == 0 || curve.points[minute - 1] == nil { segment += 1 }
            return SensorPoint(segment: segment, minute: minute, value: Double(reading))
        }
        return VStack(alignment: .leading, spacing: 6) {
            figure(curve.label.localizedCapitalized, curve.latest ?? "—")
            Chart(points) { point in
                LineMark(x: .value("Minute", point.minute), y: .value("Reading", point.value),
                         series: .value("Segment", point.segment))
                    .foregroundStyle(color)
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...1440)
            .chartXAxis {
                AxisMarks(values: [0, 360, 720, 1080, 1440]) { value in
                    AxisGridLine().foregroundStyle(LatticePalette.hairline(scheme))
                    AxisValueLabel {
                        if let minute = value.as(Int.self) {
                            Text(String(format: "%02d:00", minute / 60)).font(.caption2).foregroundStyle(dim)
                        }
                    }
                }
            }
            .frame(height: 46)
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(label).foregroundStyle(dim)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.callout)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}
