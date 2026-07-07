import SwiftUI
import AppKit
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

    /// Renders the receipt PNG eagerly and writes it into a fresh, uniquely named subdirectory of the
    /// temporary directory, keyed to the receipt's day. The per-invocation subdirectory guarantees repeated
    /// shares never collide or clobber a file a target app is still holding. Returns the file URL, or nil on
    /// a render or write failure.
    static func temporaryPNG(for reconciliation: Reconciliation) -> URL? {
        guard let data = pngData(for: reconciliation) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteLife-Share-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(defaultFilename(reconciliation, ext: "png"))
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Surfaces a render/write failure with the same plain warning alert the save path uses, so a silent
    /// failed share never reads as success.
    static func presentShareFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Could not share the receipt"
        alert.informativeText = "The receipt image could not be rendered."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func dateStamp(_ dayEpoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(dayEpoch))
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Holds the live NSView the sharing picker anchors to, and drives the eager share. Rendering the PNG on
/// click (not deferred) is the whole fix: the bytes exist and are written to a file before the picker
/// opens, so the target app receives the attachment even though the MenuBarExtra panel may close. The file
/// URL is the reliable payload for Messages and Mail.
@MainActor
final class ReceiptSharePresenter: NSObject, ObservableObject, NSSharingServicePickerDelegate {
    fileprivate weak var anchorView: NSView?
    /// Retains the live picker while its menu is open. `show(relativeTo:)` returns immediately on
    /// modern macOS, so a local would deallocate under the open menu and the share could die before
    /// a target is chosen — the exact symptom this iteration fixes.
    private var activePicker: NSSharingServicePicker?

    func share(_ reconciliation: Reconciliation) {
        guard let url = ReceiptExporter.temporaryPNG(for: reconciliation) else {
            ReceiptExporter.presentShareFailureAlert()
            return
        }
        guard let anchor = anchorView else {
            // No live anchor should be unreachable while the button is clickable; if it happens,
            // a silent no-op must not read as success.
            ReceiptExporter.presentShareFailureAlert()
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        activePicker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        // Fires on pick or cancel; the service (if any) now owns the file URL, so drop the picker.
        Task { @MainActor in self.activePicker = nil }
    }
}

/// A zero-cost NSView the sharing picker can anchor to. It fills the Share button's frame (installed as a
/// background), so the picker pops from the button's bottom edge. The coordinator binding is the presenter,
/// which captures the live view.
private struct ShareAnchor: NSViewRepresentable {
    let presenter: ReceiptSharePresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchorView = nsView
    }
}

/// The compact Share / Save toolbar shown on both receipt surfaces — the panel's receipt presentation and
/// the General Ledger day detail — in the deck's monospaced button style. Share renders the receipt PNG
/// eagerly and presents an `NSSharingServicePicker` with the written file (the social path); Save… offers
/// PNG or PDF through a save panel.
struct ReceiptToolbar: View {
    let reconciliation: Reconciliation
    @StateObject private var presenter = ReceiptSharePresenter()

    var body: some View {
        HStack(spacing: 14) {
            Button {
                presenter.share(reconciliation)
            } label: {
                Text("Share").font(.system(.caption, design: .monospaced))
            }
            .background(ShareAnchor(presenter: presenter))
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
