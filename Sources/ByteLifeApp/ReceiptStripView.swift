import SwiftUI
import ByteLifeCore

/// The daily receipt as a real thermal-printer strip. It renders the artifact's receipt text verbatim in
/// a fixed-width monospaced face so the itemized columns line up to the character, and it is a receipt:
/// the paper stays paper-colored in both appearances, sitting slightly lifted off the chassis on a soft
/// drop shadow. The chrome is a genuine tear — triangular teeth cut into the top and bottom edges. A
/// sealed day's footer prints a barcode drawn deterministically from the content hash with the hash
/// beneath it; a provisional (open-day) receipt has no seal, so the footer is simply absent and the DAY
/// OPEN header line takes the stamp's weight instead. The view only reads and colours the text it was
/// given; the stamp line alone takes colour (brass gold for BALANCED, oxblood for FLAGGED), and no
/// figure is ever recomposed.
struct ReceiptStripView: View {
    let artifact: ReceiptArtifact
    /// Point size of the monospaced tape. The panel uses the compact default; the window enlarges it.
    var fontSize: CGFloat = 11

    @Environment(\.colorScheme) private var scheme

    /// Receipt ink is always dark on cream paper, regardless of the system appearance, because a receipt
    /// is paper. The stamp line overrides this with brass or oxblood.
    private let ink = LedgerPalette.ink
    private var lines: [String] { artifact.text.components(separatedBy: "\n") }

    /// Tooth geometry for the torn top and bottom edges. Content is inset by `toothHeight` so no text or
    /// bar ever collides with a tooth.
    private let toothWidth: CGFloat = 9
    private let toothHeight: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            tape
            // The barcode is drawn from the seal, and a provisional receipt has none: no hash, no bars.
            if let hash = artifact.contentHash {
                barcodeFooter(hash)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, toothHeight + 12)
        .padding(.bottom, toothHeight + 12)
        .fixedSize(horizontal: true, vertical: false)
        .background(paper)
    }

    // MARK: - Paper

    /// The torn cream paper silhouette, filled paper-colored in both appearances and lifted off the
    /// chassis by a soft shadow (deeper on the dark deck, gentle on light).
    private var paper: some View {
        TornPaper(toothWidth: toothWidth, toothHeight: toothHeight)
            .fill(LedgerPalette.paper)
            .overlay {
                // On light appearance the cream paper sits on near-white surfaces, so a faint warm
                // edge keeps the tear legible even where the lift shadow renders weakly.
                if scheme == .light {
                    TornPaper(toothWidth: toothWidth, toothHeight: toothHeight)
                        .stroke(LedgerPalette.ink.opacity(0.12), lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.20), radius: 7, x: 0, y: 3)
    }

    // MARK: - Tape

    private var tape: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: fontSize, design: .monospaced))
                    .monospacedDigit()
                    .fontWeight(isStamp(line) ? .semibold : .regular)
                    .foregroundStyle(colour(for: line))
            }
        }
    }

    /// The stamp line is the only place brass gold is allowed, so resolution always reads as gold.
    /// A FLAGGED stamp prints in oxblood, an arrears posting in plain ink; note lines stay in ink.
    private func colour(for line: String) -> Color {
        if line.contains("* BALANCED *") { return LedgerPalette.brass }
        if line.contains("* FLAGGED *") { return LedgerPalette.debit }
        return ink
    }

    /// The stamp line, plus the provisional receipt's DAY OPEN header, which sits where the stamp would
    /// and takes its weight (but plain ink: an open day has earned no colour).
    private func isStamp(_ line: String) -> Bool {
        line.contains("* BALANCED *") || line.contains("* FLAGGED *")
            || line.contains("* POSTED IN ARREARS *") || line.contains("DAY OPEN — FIGURES AS OF")
    }

    // MARK: - Barcode footer

    /// The footer barcode, drawn deterministically from the receipt's content hash, with the hash printed
    /// beneath it in small monospaced type. Both come straight off the stored artifact, so a shared or
    /// exported receipt stays tamper-evident: the same hash always draws the same bars.
    private func barcodeFooter(_ hash: String) -> some View {
        VStack(spacing: 5) {
            BarcodeView(modules: ReceiptBarcode.modules(for: hash), ink: ink)
                .frame(maxWidth: .infinity)
            Text(hash)
                .font(.system(size: fontSize - 2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(ink.opacity(0.85))
        }
        .padding(.top, 10)
    }
}

/// Draws a barcode from `ReceiptBarcode` module widths: bars (even index) inked, spaces (odd index) left
/// as paper. A fixed module unit keeps the whole barcode narrower than the tape so it never widens the
/// strip.
private struct BarcodeView: View {
    let modules: [Int]
    let ink: Color
    var unit: CGFloat = 2
    var height: CGFloat = 30

    private var totalWidth: CGFloat { CGFloat(modules.reduce(0, +)) * unit }

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            for (index, width) in modules.enumerated() {
                let w = CGFloat(width) * unit
                if index.isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(ink))
                }
                x += w
            }
        }
        .frame(width: totalWidth, height: height)
    }
}

/// The receipt paper silhouette: a rectangle whose top and bottom edges are cut into triangular teeth, a
/// real tear rather than a dashed rule. The teeth are a uniform sawtooth of period `toothWidth` and depth
/// `toothHeight`; the caller insets its content by `toothHeight` so nothing lands on a tooth.
private struct TornPaper: Shape {
    var toothWidth: CGFloat = 9
    var toothHeight: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let th = toothHeight
        let step = toothWidth / 2

        // Top edge, left -> right, sawtooth between the peak (y = 0) and the valley (y = th).
        path.move(to: CGPoint(x: 0, y: th))
        var x: CGFloat = 0
        var peak = true
        while x < w {
            let nextX = min(x + step, w)
            path.addLine(to: CGPoint(x: nextX, y: peak ? 0 : th))
            x = nextX
            peak.toggle()
        }
        path.addLine(to: CGPoint(x: w, y: th))

        // Right edge down to the bottom tooth line.
        path.addLine(to: CGPoint(x: w, y: h - th))

        // Bottom edge, right -> left, sawtooth between the peak (y = h) and the valley (y = h - th).
        x = w
        peak = true
        while x > 0 {
            let nextX = max(x - step, 0)
            path.addLine(to: CGPoint(x: nextX, y: peak ? h : h - th))
            x = nextX
            peak.toggle()
        }
        path.addLine(to: CGPoint(x: 0, y: h - th))
        path.closeSubpath()
        return path
    }
}
