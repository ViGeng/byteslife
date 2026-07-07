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

    private var bridge: MeterBridge { viewModel.meterBridge }
    /// Whether the given channel should render as live: it clears its threshold AND live mode is on.
    private func showsLive(_ channel: MeterChannel) -> Bool { liveMode && channel.isLive }
    /// The glow-softening factor for the current scheme, applied to every shadow opacity.
    private var glow: Double { LatticePalette.glow(scheme) }
    private func channel(_ kind: MeterChannelKind) -> MeterChannel? {
        bridge.channels.first { $0.kind == kind }
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
    private var heroFlowChart: some View {
        let traffic = channel(.traffic)?.rawBars ?? []
        let storage = channel(.storage)?.rawBars ?? []
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
                    Button("Open Input Monitoring Settings…") {
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
