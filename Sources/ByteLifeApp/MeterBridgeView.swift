import SwiftUI
import Charts
import ByteLifeCore

/// The Byte Flow deck: the live, chart-led face of the menubar panel. A hero flow chart shows the
/// shape of the last half hour (network in teal, disk in violet, one shared byte scale), and each
/// channel card carries a gradient sparkline in its own signal color with the live rate glowing
/// beside it. The governing rule is LIGHT IS DATA: readouts glow and the live dot pulses only while a
/// channel's smoothed rate clears its liveness threshold, the hex ticker prints real inter-poll
/// deltas, and everything settles to a quiet dark baseline when nothing flows.
struct MeterBridgeView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.colorScheme) private var scheme
    /// The persisted LIVE toggle. On, the deck behaves as before (live lights gate on each channel's
    /// threshold). Off, the readouts show the numbers as of the last open and must not pretend to be
    /// live: they render dim, without glow or pulse, regardless of `isLive`.
    @AppStorage("liveMode") private var liveMode = true

    // The persisted per-chart history windows. Each rate channel and the hero flow chart carries its own,
    // default 30M; the view model reads the same keys to size its fetch, so these stay one source of truth.
    @AppStorage(ChartWindowStore.key(.traffic)) private var trafficWindow: MeterWindow = .w30m
    @AppStorage(ChartWindowStore.key(.storage)) private var storageWindow: MeterWindow = .w30m
    @AppStorage(ChartWindowStore.key(.cognition)) private var cognitionWindow: MeterWindow = .w30m
    @AppStorage(ChartWindowStore.key(.mechanics)) private var mechanicsWindow: MeterWindow = .w30m
    @AppStorage(ChartWindowStore.heroKey) private var heroWindow: MeterWindow = .w30m

    /// The one GLOBAL WORK-window duration in minutes, configured from any chart's Custom… editor and
    /// shared by every menu's WORK option. Defaults to eight hours, the length of a working day.
    @AppStorage(ChartWindowStore.workMinutesKey) private var workMinutes: Int = ChartWindowStore.defaultWorkMinutes
    /// The identity of the chart whose Custom… editor popover is open, or nil when none is. One editor at
    /// a time; the id matches the value passed to `windowMenu`.
    @State private var customEditorID: String?

    private var bridge: MeterBridge { viewModel.meterBridge }
    /// Whether the given channel should render as live: it clears its threshold AND live mode is on.
    private func showsLive(_ channel: MeterChannel) -> Bool { liveMode && channel.isLive }
    /// The glow-softening factor for the current scheme, applied to every shadow opacity.
    private var glow: Double { LatticePalette.glow(scheme) }
    private func channel(_ kind: MeterChannelKind) -> MeterChannel? {
        bridge.channels.first { $0.kind == kind }
    }

    /// The persisted window binding for an adjustable rate channel, or nil for EXPOSURE, which has no
    /// sparkline to zoom and so carries no selector.
    private func windowBinding(for kind: MeterChannelKind) -> Binding<MeterWindow>? {
        switch kind {
        case .traffic: return $trafficWindow
        case .storage: return $storageWindow
        case .cognition: return $cognitionWindow
        case .mechanics: return $mechanicsWindow
        case .exposure: return nil
        }
    }

    /// Hands the whole current window selection to the view model after any single menu changed one, so
    /// the fetch depth and every channel's bucketing update together and the chart re-renders at once.
    private func notifyWindows() {
        viewModel.setWindows(
            [.traffic: trafficWindow, .storage: storageWindow,
             .cognition: cognitionWindow, .mechanics: mechanicsWindow],
            hero: heroWindow
        )
    }

    /// A compact dim monospaced window picker for a chart title (and the hero card). It lists the four
    /// fixed windows, the shared WORK window (labelled with its configured hours), and a Custom… item that
    /// opens the WORK-window editor for this chart. On selection it writes the persisted binding and
    /// notifies the view model. `id` distinguishes which chart's editor popover is showing.
    private func windowMenu(_ selection: Binding<MeterWindow>, id: String) -> some View {
        Menu {
            ForEach(MeterWindow.fixedCases, id: \.self) { window in
                Button {
                    selection.wrappedValue = window
                    notifyWindows()
                } label: {
                    if window == selection.wrappedValue {
                        Label(window.token, systemImage: "checkmark")
                    } else {
                        Text(window.token)
                    }
                }
            }
            Divider()
            Button {
                selectWork(selection)
            } label: {
                let label = "WORK · \(workMinutes / 60)H"
                if selection.wrappedValue.isCustom {
                    Label(label, systemImage: "checkmark")
                } else {
                    Text(label)
                }
            }
            Button("Custom…") { customEditorID = id }
        } label: {
            Text(selection.wrappedValue.token)
                .font(.system(size: 9, design: .monospaced).weight(.medium))
                .foregroundStyle(LatticePalette.dim(scheme))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: Binding(
            get: { customEditorID == id },
            set: { if !$0 { customEditorID = nil } }
        )) {
            workEditor(selection)
        }
    }

    /// Sets a chart to the shared WORK window at the current global duration and notifies the view model.
    private func selectWork(_ selection: Binding<MeterWindow>) {
        selection.wrappedValue = .custom(minutes: workMinutes)
        notifyWindows()
    }

    /// Updates the one global WORK duration and re-points every chart already on the WORK window to the new
    /// span, so a duration change moves all of them together, then notifies the view model once.
    private func applyWorkMinutes(_ minutes: Int) {
        let clamped = min(MeterWindow.customMaxRange, max(MeterWindow.customMinRange, minutes))
        workMinutes = clamped
        for kind in ChartWindowStore.adjustableChannels {
            if let binding = windowBinding(for: kind), binding.wrappedValue.isCustom {
                binding.wrappedValue = .custom(minutes: clamped)
            }
        }
        if heroWindow.isCustom { heroWindow = .custom(minutes: clamped) }
        notifyWindows()
    }

    /// The compact WORK-window editor: an hours stepper (1 to 48) over the global duration in an adaptive
    /// palette, plus a button that switches the invoking chart to the WORK window and dismisses.
    private func workEditor(_ selection: Binding<MeterWindow>) -> some View {
        let hours = Binding<Int>(
            get: { max(1, min(48, workMinutes / 60)) },
            set: { applyWorkMinutes($0 * 60) }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text("WORK WINDOW")
                .font(.system(size: 9, design: .monospaced).weight(.semibold))
                .foregroundStyle(LatticePalette.dim(scheme))
            Stepper(value: hours, in: 1...48) {
                Text("\(hours.wrappedValue) h")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(LatticePalette.dial(scheme))
            }
            Button {
                selectWork(selection)
                customEditorID = nil
            } label: {
                Text("Use WORK window")
                    .font(.system(size: 10, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LatticePalette.teal(scheme))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 168)
        .background(LatticePalette.card(scheme))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            heroFlowChart
            ForEach(bridge.channels) { channel in
                if channel.kind == .exposure {
                    exposureCard(channel)
                } else {
                    rateCard(channel)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("BYTELIFE // FLOW")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(LatticePalette.dim(scheme))
                Spacer()
                liveChip
            }

            // The hero: today's posted byte volume, glowing softly and rolling as it climbs.
            Text(viewModel.daySheet.postedByteVolume)
                .font(.system(size: 26, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .foregroundStyle(LatticePalette.dial(scheme))
                .shadow(color: LatticePalette.amber(scheme).opacity(0.35 * glow), radius: 6)

            combinedFlowLine
            hexTicker
        }
    }

    /// The LIVE chip is now a control. In live mode it lights amber only while some channel clears its
    /// threshold (today's behavior); with live mode off it renders as a dim outlined OFF state, since the
    /// readouts are as of open and nothing is ticking. Tapping toggles live mode and hands the value to
    /// the view model, which starts or stops the fast timer.
    private var liveChip: some View {
        let lit = liveMode && bridge.anyLive
        return Button {
            liveMode.toggle()
            viewModel.setLiveMode(liveMode)
        } label: {
            Text("LIVE")
                .font(.system(size: 9, design: .monospaced).weight(.bold))
                .foregroundStyle(lit ? LatticePalette.chassis(.dark) : LatticePalette.dim(scheme))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(lit ? LatticePalette.amber(scheme) : LatticePalette.card(scheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(liveMode ? Color.clear : LatticePalette.dim(scheme).opacity(0.5),
                                        lineWidth: 1)
                        )
                )
                .shadow(color: lit ? LatticePalette.amber(scheme).opacity(0.5 * glow) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
    }

    private var combinedFlowLine: some View {
        let byteChannelsLive = liveMode
            && ((channel(.traffic)?.isLive ?? false) || (channel(.storage)?.isLive ?? false))
        return Text("▲ \(ByteFormatting.byteRate(bridge.combinedByteRate))")
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .foregroundStyle(byteChannelsLive ? LatticePalette.teal(scheme) : LatticePalette.dim(scheme))
            .shadow(color: byteChannelsLive ? LatticePalette.teal(scheme).opacity(0.4 * glow) : .clear, radius: 3)
    }

    /// Real inter-poll byte deltas in hexadecimal, newest first. Pure byte texture, zero fakery.
    private var hexTicker: some View {
        Text(viewModel.tickerDeltas.isEmpty
             ? "Δ —"
             : "Δ " + viewModel.tickerDeltas.map(ByteFormatting.hex).joined(separator: " · "))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(LatticePalette.teal(scheme).opacity(0.4))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: - Hero flow chart

    private struct FlowPoint: Identifiable {
        let series: String
        let minute: Int
        let rate: Double
        var id: String { "\(series)-\(minute)" }
    }

    /// Network and disk on ONE absolute bytes/s scale, so the taller series really is the bigger flow.
    /// The hero carries its own window (independent of the TRAFFIC and STORAGE cards), so it reads the
    /// bridge's hero-window bucket series rather than either channel's `rawBars`.
    private var heroFlowChart: some View {
        let traffic = bridge.heroTraffic
        let storage = bridge.heroStorage
        var points: [FlowPoint] = []
        points += traffic.enumerated().map { FlowPoint(series: "traffic", minute: $0.offset, rate: $0.element) }
        points += storage.enumerated().map { FlowPoint(series: "storage", minute: $0.offset, rate: $0.element) }
        // A floor on the domain keeps an idle half hour reading flat instead of zooming into noise.
        let maxY = max((traffic + storage).max() ?? 0, 65_536)

        return Chart(points) { point in
            AreaMark(
                x: .value("Minute", point.minute),
                y: .value("Rate", point.rate),
                series: .value("Series", point.series)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(by: .value("Series", point.series))
            .opacity(0.25)

            LineMark(
                x: .value("Minute", point.minute),
                y: .value("Rate", point.rate),
                series: .value("Series", point.series)
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .foregroundStyle(by: .value("Series", point.series))
        }
        .chartForegroundStyleScale([
            "traffic": LatticePalette.teal(scheme),
            "storage": LatticePalette.violet(scheme),
        ])
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...maxY)
        .frame(height: 56)
        .padding(8)
        .background(cardShape)
        // The hero's own window selector, floated in the corner so the chart keeps its full height.
        .overlay(alignment: .topTrailing) {
            windowMenu($heroWindow, id: "hero")
                .padding(.top, 5)
                .padding(.trailing, 8)
        }
    }

    // MARK: - Channel cards

    private func rateCard(_ channel: MeterChannel) -> some View {
        let color = LatticePalette.channel(channel.kind, scheme)
        // With live mode off the readout is as of the last open, so it drops its glow and pulse and reads
        // dim, regardless of the channel's own liveness.
        let live = showsLive(channel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(channel.title)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color.opacity(0.85))
                if live { PulseDot(color: color, glow: glow) }
                if let binding = windowBinding(for: channel.kind) { windowMenu(binding, id: channel.kind.rawValue) }
                Spacer()
                Text(channel.rateReadout)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .foregroundStyle(live ? color : LatticePalette.dim(scheme))
                    .shadow(color: live ? color.opacity(0.45 * glow) : .clear, radius: 3)
            }

            sparkline(channel, color: color)

            if let split = channel.tokenSplit {
                ratioBar(split, color: color)
            }

            HStack {
                Text(channel.subline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !channel.peakReadout.isEmpty, channel.peak > 0 {
                    Text("peak \(channel.peakReadout)")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(LatticePalette.dim(scheme))

            if let tag = channel.uncalibratedTag {
                uncalibratedRow(tag: tag, needsPermission: channel.needsPermission, color: color)
            }
        }
        .padding(8)
        .background(cardShape)
    }

    /// The channel's last half hour as a gradient area sparkline in its signal color, with the window
    /// maximum held as a dial-white dot.
    private func sparkline(_ channel: MeterChannel, color: Color) -> some View {
        let bars = channel.bars
        let peakIndex = channel.rawBars.indices.max(by: { channel.rawBars[$0] < channel.rawBars[$1] })
        let hasSignal = (channel.rawBars.max() ?? 0) > 0

        return Chart {
            ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("Minute", i), y: .value("Level", v))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [color.opacity(0.4), color.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Minute", i), y: .value("Level", v))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .foregroundStyle(color)
            }
            if hasSignal, let peakIndex {
                PointMark(x: .value("Minute", peakIndex), y: .value("Level", bars[peakIndex]))
                    .symbolSize(18)
                    .foregroundStyle(LatticePalette.dial(scheme))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
        .frame(height: 24)
    }

    /// COGNITION's prompted-versus-generated split: the exchange rate as a shape.
    private func ratioBar(_ split: TokenSplit, color: Color) -> some View {
        let total = max(1, split.payable + split.receivable)
        let payableFraction = CGFloat(split.payable) / CGFloat(total)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.35))
                    .frame(width: max(0, geo.size.width * payableFraction))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
            }
        }
        .frame(height: 3)
    }

    private func uncalibratedRow(tag: String, needsPermission: Bool, color: Color) -> some View {
        HStack {
            Text(tag)
                .font(.system(size: 9, design: .monospaced).weight(.medium))
                .foregroundStyle(color.opacity(0.7))
                .lineLimit(1)
            Spacer()
            if needsPermission {
                Menu {
                    Button("Grant Permission…") { viewModel.requestInputPermission() }
                    // Revealed once a Grant returned with the grant still absent (macOS suppresses the
                    // repeat prompt): resets the TCC decision so the prompt genuinely fires again, and
                    // surfaces an alert if tccutil itself fails.
                    if viewModel.inputPromptSuppressed {
                        Button("Reset permission state…") {
                            if let exitCode = viewModel.resetInputPermission() {
                                PermissionsHint.presentResetFailure(exitCode: exitCode)
                            }
                        }
                    }
                    Button("Open System Settings (search “Input Monitoring”)…") {
                        PermissionsHint.openInputMonitoringSettings()
                    }
                } label: {
                    Text("calibrate")
                        .font(.system(size: 9, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Exposure card

    /// Attention is the one absolute-scale channel, so it earns the one radial element: a ring showing
    /// the fraction of the day spent attentive, with the accumulated duration beside it.
    private func exposureCard(_ channel: MeterChannel) -> some View {
        let color = LatticePalette.channel(.exposure, scheme)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(LatticePalette.hairline(scheme), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.003, channel.exposureFraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.4 * glow), radius: 2)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(channel.title)
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(color.opacity(0.85))
                    Spacer()
                    Text(channel.exposureReadout)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: false))
                        .foregroundStyle(color)
                        .shadow(color: color.opacity(0.45 * glow), radius: 3)
                }
                Text(channel.subline)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(LatticePalette.dim(scheme))
                if let tag = channel.uncalibratedTag {
                    Text(tag)
                        .font(.system(size: 9, design: .monospaced).weight(.medium))
                        .foregroundStyle(color.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape)
    }

    // MARK: - Shared

    private var cardShape: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LatticePalette.card(scheme))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LatticePalette.hairline(scheme), lineWidth: 1))
    }
}

/// The per-channel live cursor: a small dot in the channel color that breathes while data flows. It is
/// inserted only when the channel reads live, so removal ends the animation and a quiet panel is still.
private struct PulseDot: View {
    let color: Color
    /// The scheme glow factor, so the breathing dot's halo softens on light like every other glow.
    var glow: Double = 1.0
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(bright ? 1.0 : 0.35)
            .shadow(color: color.opacity(0.6 * glow), radius: 3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}
