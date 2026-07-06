import SwiftUI
import ByteLifeCore

/// The nightly receipt as a tall, narrow thermal-printer strip. It renders the *stored* receipt text
/// verbatim in a fixed-width monospaced face so the itemized columns line up to the character, keeps a
/// subtle perforated edge top and bottom, and colours the stamp line alone: brass gold for BALANCED
/// (the one place gold appears), oxblood for FLAGGED. The artifact is immutable, so the view only reads
/// and colours the text it was given; it never recomposes a figure.
struct ReceiptStripView: View {
    let reconciliation: Reconciliation
    /// Point size of the monospaced tape. The panel uses the compact default; the window enlarges it.
    var fontSize: CGFloat = 11

    @Environment(\.colorScheme) private var scheme

    private var ink: Color { LedgerPalette.primaryInk(scheme) }
    private var lines: [String] { reconciliation.receiptText.components(separatedBy: "\n") }

    var body: some View {
        VStack(spacing: 0) {
            perforation
            tape
            perforation
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(LedgerPalette.surface(scheme))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The stamp line is the only place brass gold is allowed, so resolution always reads as gold.
    /// A FLAGGED stamp prints in oxblood, an arrears posting in plain ink; note lines stay in ink.
    private func colour(for line: String) -> Color {
        if line.contains("* BALANCED *") { return LedgerPalette.brass }
        if line.contains("* FLAGGED *") { return LedgerPalette.debit }
        return ink
    }

    private func isStamp(_ line: String) -> Bool {
        line.contains("* BALANCED *") || line.contains("* FLAGGED *") || line.contains("* POSTED IN ARREARS *")
    }

    // MARK: - Perforation

    /// A faint dashed tear line standing in for the tape's perforated edge. Deliberately understated:
    /// a thin, low-contrast pencil-gray rule, never a photographic printer bezel. It spans whatever
    /// width the tape settles at without forcing the strip any wider.
    private var perforation: some View {
        PerforationRule()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            .foregroundStyle(LedgerPalette.pencil.opacity(0.6))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

/// A single horizontal line drawn across the middle of its rect, dashed by the caller's stroke style
/// into the receipt's subtle perforation edge.
private struct PerforationRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}
