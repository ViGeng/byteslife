import SwiftUI
import Charts
import ByteLifeCore

struct LedgerHistoryView: View {
    enum Range: Int, CaseIterable {
        case month = 30
        case quarter = 90
        case year = 365

        var label: String { "\(rawValue) days" }
    }

    enum Presentation: String, CaseIterable {
        case trend = "Trend"
        case heatmap = "Heatmap"
    }

    struct Preferences {
        var metrics: [LedgerModule: LedgerHistoryMetric] = [:]
        var range = Range.month
        var presentation = Presentation.trend
        var ending: Date?
    }

    @ObservedObject var vm: GeneralLedgerViewModel
    let module: LedgerModule
    @Binding var preferences: Preferences
    let openDay: (Int64) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var selectedIndex: Int?

    private var metric: LedgerHistoryMetric { preferences.metrics[module] ?? module.metrics[0] }
    private var today: Date { Date(timeIntervalSince1970: TimeInterval(vm.todayEpoch)) }
    private var end: Date { preferences.ending ?? today }
    private var dayCount: Int { preferences.range.rawValue }
    private var dim: Color { LatticePalette.dim(scheme) }
    private var color: Color { module.color(scheme) }

    var body: some View {
        let history = vm.history(for: metric, dayCount: dayCount, ending: end)
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    rangeControls(history.days)
                    historyPanel(history)
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: metric) { _, _ in selectedIndex = nil }
        .onChange(of: preferences.range) { _, _ in selectedIndex = nil }
        .onChange(of: end) { _, _ in selectedIndex = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            module.icon(scheme, size: 38)
            Text(module.rawValue)
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Picker("Metric", selection: Binding(get: { metric }, set: { preferences.metrics[module] = $0 })) {
                ForEach(module.metrics) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private func rangeControls(_ days: [LedgerHistory.Day]) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    shiftRange(by: -dayCount)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!hasEarlierDays(than: days.first))
                .accessibilityLabel("Previous \(dayCount) days")
                .help("Previous \(dayCount) days")

                Button {
                    shiftRange(by: dayCount)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(preferences.ending == nil)
                .accessibilityLabel("Next \(dayCount) days")
                .help("Next \(dayCount) days")
            }
            if let first = days.first, let last = days.last {
                Text("\(dateLabel(first.dayEpoch)) – \(dateLabel(last.dayEpoch))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            if preferences.ending != nil {
                Button("Latest") { preferences.ending = nil }
            }
            Spacer()
            Picker("Date range", selection: $preferences.range) {
                ForEach(Range.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private func historyPanel(_ history: LedgerHistory) -> some View {
        let readings = history.days.compactMap(\.value)
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.label)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(readings.count) of \(history.days.count) days with data")
                        .font(.callout)
                        .foregroundStyle(dim)
                }
                Spacer()
                Picker("Chart type", selection: $preferences.presentation) {
                    ForEach(Presentation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            switch preferences.presentation {
            case .trend:
                if let peak = readings.max() {
                    trend(history.days, peak: peak)
                    trendSelection(history.days)
                } else {
                    ContentUnavailableView("No data in this range", systemImage: "chart.bar.xaxis")
                        .frame(height: 240)
                }
            case .heatmap:
                LedgerHeatmapView(history: history, metric: metric, color: color,
                                  peak: readings.max() ?? 0, openDay: openDay)
            }
        }
        .padding(20)
        .background(LatticePalette.chassis(scheme).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LatticePalette.hairline(scheme)))
    }

    private func trend(_ days: [LedgerHistory.Day], peak: Int64) -> some View {
        let step = max(1, (days.count + 5) / 6)
        let ticks = Array(stride(from: 0, to: days.count, by: step))
        let barWidth = min(16, 440 / Double(days.count))
        return Chart {
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                if let value = day.value {
                    if value == 0 {
                        PointMark(x: .value("Day", Double(index)), y: .value(metric.label, 0.0))
                            .symbolSize(12)
                            .foregroundStyle(color)
                            .accessibilityLabel(DayLabel.full(dayEpoch: day.dayEpoch))
                            .accessibilityValue(metric.formatted(value))
                    } else {
                        BarMark(x: .value("Day", Double(index)), y: .value(metric.label, Double(value)),
                                width: .fixed(barWidth))
                            .foregroundStyle(color.opacity(selectedIndex == index ? 1 : 0.78))
                            .accessibilityLabel(DayLabel.full(dayEpoch: day.dayEpoch))
                            .accessibilityValue(metric.formatted(value))
                    }
                }
            }
            if let selectedIndex {
                RuleMark(x: .value("Selected day", Double(selectedIndex)))
                    .foregroundStyle(color.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: -0.5...(Double(days.count) - 0.5))
        .chartYScale(domain: 0...Double(max(1, peak)))
        .chartXAxis {
            AxisMarks(values: ticks.map(Double.init)) { tick in
                AxisTick().foregroundStyle(dim)
                AxisValueLabel {
                    if let position = tick.as(Double.self), let index = Int(exactly: position),
                       days.indices.contains(index) {
                        Text(DayLabel.short(dayEpoch: days[index].dayEpoch)).font(.caption2).foregroundStyle(dim)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { tick in
                AxisGridLine().foregroundStyle(LatticePalette.hairline(scheme))
                AxisValueLabel {
                    if let amount = tick.as(Double.self), let whole = Int64(exactly: amount) {
                        Text(metric.formatted(whole)).font(.caption2).foregroundStyle(dim)
                    }
                }
            }
        }
        .chartOverlay { chart in
            GeometryReader { geometry in
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let frame = chart.plotFrame.map({ geometry[$0] }), frame.contains(event.location),
                              let position: Double = chart.value(atX: event.location.x - frame.minX) else { return }
                        let index = Int(position.rounded())
                        if days.indices.contains(index) { selectedIndex = index }
                    })
            }
        }
        .accessibilityLabel("Daily trend")
        .frame(height: 245)
    }

    private func trendSelection(_ days: [LedgerHistory.Day]) -> some View {
        HStack {
            if let selectedIndex, days.indices.contains(selectedIndex) {
                let day = days[selectedIndex]
                Text(DayLabel.full(dayEpoch: day.dayEpoch))
                Spacer()
                if let value = day.value {
                    Text(metric.formatted(value)).monospacedDigit()
                    Button("Open day") { openDay(day.dayEpoch) }
                } else {
                    Text("No data").foregroundStyle(dim)
                }
            } else {
                Text("Select a day in the chart to see its value.").foregroundStyle(dim)
            }
        }
        .font(.callout)
        .frame(minHeight: 24)
    }

    private func dateLabel(_ epoch: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func hasEarlierDays(than first: LedgerHistory.Day?) -> Bool {
        guard let earliest = vm.earliestDay, let first else { return false }
        return earliest.timeIntervalSince1970 < Double(first.dayEpoch)
    }

    private func shiftRange(by days: Int) {
        guard let shifted = Calendar.current.date(byAdding: .day, value: days, to: end) else { return }
        preferences.ending = shifted < today ? shifted : nil
    }
}

private struct LedgerHeatmapView: View {
    let history: LedgerHistory
    let metric: LedgerHistoryMetric
    let color: Color
    let peak: Int64
    let openDay: (Int64) -> Void

    @Environment(\.colorScheme) private var scheme

    private var dim: Color { LatticePalette.dim(scheme) }
    private var weekNames: [String] { ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                calendar(cellSize: 25, gap: 4)
                calendar(cellSize: 16, gap: 3)
                calendar(cellSize: 9, gap: 2)
            }
            HStack(spacing: 7) {
                swatch(fill(nil))
                Text("No data").padding(.trailing, 8)
                swatch(fill(0))
                Text("Zero").padding(.trailing, 8)
                Text("Low")
                ForEach([0.28, 0.47, 0.68, 0.95], id: \.self) { opacity in
                    swatch(color.opacity(opacity))
                }
                Text("High")
                Spacer()
                if peak > 0 {
                    Text("Peak \(metric.formatted(peak))").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(dim)
        }
    }

    private func calendar(cellSize: CGFloat, gap: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 7) {
            VStack(alignment: .trailing, spacing: gap) {
                Color.clear.frame(width: 30, height: 14)
                ForEach(weekNames.indices, id: \.self) { weekday in
                    Text(weekday.isMultiple(of: 2) ? weekNames[weekday] : "")
                        .font(.system(size: cellSize <= 10 ? 8 : 10))
                        .foregroundStyle(dim)
                        .frame(height: cellSize)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: gap) {
                ForEach(history.weeks.indices, id: \.self) { index in
                    week(history.weeks[index], isFirst: index == 0, cellSize: cellSize, gap: gap)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily heatmap")
    }

    private func week(_ days: [LedgerHistory.Day?], isFirst: Bool, cellSize: CGFloat, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            Color.clear.frame(width: cellSize, height: 14)
                .overlay(alignment: .leading) {
                    if let month = monthLabel(days, isFirst: isFirst) {
                        Text(month)
                            .font(.caption2)
                            .foregroundStyle(dim)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
            ForEach(days.indices, id: \.self) { index in
                cell(days[index], size: cellSize)
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: LedgerHistory.Day?, size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size > 10 ? 3 : 2)
        if let day {
            let label = DayLabel.full(dayEpoch: day.dayEpoch)
            if let value = day.value {
                let amount = metric.formatted(value)
                Button {
                    openDay(day.dayEpoch)
                } label: {
                    shape.fill(fill(value)).frame(width: size, height: size)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(amount)
                .help("\(label) · \(amount)")
            } else {
                shape.fill(fill(nil)).frame(width: size, height: size)
                    .accessibilityElement()
                    .accessibilityLabel(label)
                    .accessibilityValue("No data")
                    .help("\(label) · No data")
            }
        } else {
            Color.clear.frame(width: size, height: size).accessibilityHidden(true)
        }
    }

    private func fill(_ value: Int64?) -> Color {
        guard let value else { return LatticePalette.hairline(scheme) }
        guard value > 0 else { return color.opacity(0.13) }
        let fraction = Double(value) / Double(max(peak, 1))
        return color.opacity(0.25 + 0.70 * sqrt(fraction))
    }

    private func swatch(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(fill).frame(width: 11, height: 11)
            .accessibilityHidden(true)
    }

    private func monthLabel(_ days: [LedgerHistory.Day?], isFirst: Bool) -> String? {
        let calendar = Calendar.current
        let dates = days.compactMap { $0 }.map { Date(timeIntervalSince1970: TimeInterval($0.dayEpoch)) }
        let boundary = dates.first { calendar.component(.day, from: $0) == 1 }
        let firstOfRange = isFirst ? dates.first : nil
        let leadingMonth = firstOfRange.flatMap { date in
            calendar.date(byAdding: .day, value: 7, to: date).flatMap { nextWeek in
                calendar.isDate(date, equalTo: nextWeek, toGranularity: .month) ? date : nil
            }
        }
        guard let date = boundary ?? leadingMonth else { return nil }
        return DayLabel.abbreviatedMonth(calendar.component(.month, from: date))
    }
}
