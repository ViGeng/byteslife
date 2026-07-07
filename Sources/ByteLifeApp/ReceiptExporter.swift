import SwiftUI
import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import ByteLifeCore

/// The self-contained share rendering of a receipt: the stored strip on its torn cream paper, matted on a
/// neutral card so the drop shadow reads, at a fixed light appearance independent of any panel state. Both
/// the PNG and PDF exporters render exactly this, so every shared or saved artifact carries the verbatim
/// receipt text, its content hash, and the barcode — a shared receipt stays tamper-evident.
struct ReceiptShareView: View {
    let reconciliation: Reconciliation

    var body: some View {
        ReceiptStripView(reconciliation: reconciliation, fontSize: 12)
            .environment(\.colorScheme, .light)
            .padding(28)
            .background(Color(red: 0.93, green: 0.93, blue: 0.92))
    }
}

/// The two artifact formats the receipt exports to.
enum ReceiptFileFormat {
    case png
    case pdf
}

/// Renders a receipt to a shareable PNG or a vector PDF via `ImageRenderer`, and drives the save panel.
/// PNG goes through the rendered `CGImage`; PDF draws vector-side into a `CGContext` PDF page sized to the
/// receipt, so it stays crisp rather than a rasterized image. Main-actor bound because `ImageRenderer` is.
@MainActor
enum ReceiptExporter {
    /// A 2x renderer over the self-contained share view.
    private static func renderer(for reconciliation: Reconciliation) -> ImageRenderer<ReceiptShareView> {
        let renderer = ImageRenderer(content: ReceiptShareView(reconciliation: reconciliation))
        renderer.scale = 2
        return renderer
    }

    /// PNG bytes for the receipt, encoded from the rendered CGImage, or nil when rendering is unavailable.
    static func pngData(for reconciliation: Reconciliation) -> Data? {
        guard let cgImage = renderer(for: reconciliation).cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Vector PDF bytes for the receipt: a single page sized to the rendered content, drawn through the
    /// renderer's CGContext pass rather than rasterized. Nil when rendering is unavailable.
    static func pdfData(for reconciliation: Reconciliation) -> Data? {
        let data = NSMutableData()
        var produced = false
        renderer(for: reconciliation).render { size, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            pdf.beginPDFPage(nil)
            renderInContext(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            produced = true
        }
        return produced ? (data as Data) : nil
    }

    /// The suggested file name for a receipt export, keyed to its accounting day.
    static func defaultFilename(_ reconciliation: Reconciliation, ext: String) -> String {
        "ByteLife-Receipt-\(dateStamp(reconciliation.dayEpoch)).\(ext)"
    }

    /// Renders the receipt in `format` and writes it through a save panel restricted to that type.
    static func save(_ reconciliation: Reconciliation, as format: ReceiptFileFormat) {
        let payload: (data: Data?, type: UTType, ext: String)
        switch format {
        case .png: payload = (pngData(for: reconciliation), .png, "png")
        case .pdf: payload = (pdfData(for: reconciliation), .pdf, "pdf")
        }
        guard let data = payload.data else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [payload.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename(reconciliation, ext: payload.ext)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            // A silent failed save would read as success; surface it plainly.
            let alert = NSAlert()
            alert.messageText = "Could not save the receipt"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func dateStamp(_ dayEpoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(dayEpoch))
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The PNG payload the system share sheet carries. Rendering is deferred into the transfer closure so the
/// toolbar stays cheap, and the shared bytes are exactly `ReceiptExporter.pngData`, hash and barcode
/// included.
struct ReceiptShareItem: Transferable, Sendable {
    let reconciliation: Reconciliation
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = await ReceiptExporter.pngData(for: item.reconciliation) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
        .suggestedFileName { $0.filename }
    }
}

/// The compact Share / Save toolbar shown on both receipt surfaces — the panel's receipt presentation and
/// the General Ledger day detail — in the deck's monospaced button style. Share opens the system share
/// sheet with the PNG (the social path); Save… offers PNG or PDF through a save panel.
struct ReceiptToolbar: View {
    let reconciliation: Reconciliation

    private var shareItem: ReceiptShareItem {
        ReceiptShareItem(
            reconciliation: reconciliation,
            filename: ReceiptExporter.defaultFilename(reconciliation, ext: "png")
        )
    }

    var body: some View {
        HStack(spacing: 14) {
            ShareLink(
                item: shareItem,
                preview: SharePreview("BYTELIFE receipt", image: Image(systemName: "doc.plaintext"))
            ) {
                Text("Share").font(.system(.caption, design: .monospaced))
            }
            Menu {
                Button("PNG") { ReceiptExporter.save(reconciliation, as: .png) }
                Button("PDF") { ReceiptExporter.save(reconciliation, as: .pdf) }
            } label: {
                Text("Save…").font(.system(.caption, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
