import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import ByteLifeCore

/// The self-contained share rendering of a receipt: the strip on its torn cream paper, matted on a
/// neutral card so the drop shadow reads, at a fixed light appearance independent of any panel state.
/// The PNG, PDF, and print paths all render exactly this, so a sealed artifact always carries its
/// verbatim text, content hash, and barcode (tamper-evident), and a provisional one always carries its
/// DAY OPEN header and no barcode (an honest draft).
struct ReceiptShareView: View {
    let artifact: ReceiptArtifact

    var body: some View {
        ReceiptStripView(artifact: artifact, fontSize: 12)
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
    private static func renderer(for artifact: ReceiptArtifact) -> ImageRenderer<ReceiptShareView> {
        let renderer = ImageRenderer(content: ReceiptShareView(artifact: artifact))
        renderer.scale = 2
        return renderer
    }

    /// PNG bytes for the receipt, encoded from the rendered CGImage, or nil when rendering is unavailable.
    static func pngData(for artifact: ReceiptArtifact) -> Data? {
        guard let cgImage = renderer(for: artifact).cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Vector PDF bytes for the receipt: a single page sized to the rendered content, drawn through the
    /// renderer's CGContext pass rather than rasterized. Nil when rendering is unavailable.
    static func pdfData(for artifact: ReceiptArtifact) -> Data? {
        let data = NSMutableData()
        var produced = false
        renderer(for: artifact).render { size, renderInContext in
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
    static func defaultFilename(_ artifact: ReceiptArtifact, ext: String) -> String {
        "ByteLife-Receipt-\(dateStamp(artifact.dayEpoch)).\(ext)"
    }

    /// Renders the receipt in `format` and writes it through a save panel restricted to that type.
    static func save(_ artifact: ReceiptArtifact, as format: ReceiptFileFormat) {
        let payload: (data: Data?, type: UTType, ext: String)
        switch format {
        case .png: payload = (pngData(for: artifact), .png, "png")
        case .pdf: payload = (pdfData(for: artifact), .pdf, "pdf")
        }
        guard let data = payload.data else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [payload.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename(artifact, ext: payload.ext)
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
    static func temporaryPNG(for artifact: ReceiptArtifact) -> URL? {
        guard let data = pngData(for: artifact) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ByteLife-Share-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(defaultFilename(artifact, ext: "png"))
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Runs the system print sheet over the receipt's vector-PDF render, scaled down to fit the page.
    /// The sheet anchors to `window` — printing needs a real, stable host — and falls back to the
    /// app-modal dialog when none is available, the same posture as the save panel. A provisional
    /// receipt prints exactly as it renders: DAY OPEN header, no barcode.
    static func printReceipt(_ artifact: ReceiptArtifact, anchoredTo window: NSWindow?) {
        guard let data = pdfData(for: artifact),
              let document = PDFDocument(data: data),
              let operation = document.printOperation(
                  for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true
              )
        else {
            // A silently swallowed print click would read as a working feature; surface it plainly.
            let alert = NSAlert()
            alert.messageText = "Could not print the receipt"
            alert.informativeText = "The receipt could not be rendered for printing."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
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

    func share(_ artifact: ReceiptArtifact) {
        guard let url = ReceiptExporter.temporaryPNG(for: artifact) else {
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
/// which captures the live view. Used inside the stable Receipt window, where anchoring stays valid.
struct ShareAnchor: NSViewRepresentable {
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

/// The Save… control shared by every receipt surface: PNG or PDF through a blocking save panel. Save is
/// unaffected by the window rework because `NSSavePanel` runs modally and needs no stable host window.
struct ReceiptSaveMenu: View {
    let artifact: ReceiptArtifact

    var body: some View {
        Menu {
            Button("PNG") { ReceiptExporter.save(artifact, as: .png) }
            Button("PDF") { ReceiptExporter.save(artifact, as: .pdf) }
        } label: {
            Text("Save…").font(.system(.caption, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The Print… control shared by every receipt surface: it renders the vector PDF and runs the system
/// print sheet anchored to whatever real window hosts the button, captured by a zero-cost background
/// view the same way the share picker anchors.
struct ReceiptPrintButton: View {
    let artifact: ReceiptArtifact
    @State private var hostWindow: NSWindow?

    var body: some View {
        Button {
            ReceiptExporter.printReceipt(artifact, anchoredTo: hostWindow)
        } label: {
            Text("Print…").font(.system(.caption, design: .monospaced))
        }
        .background(HostWindowAnchor(window: $hostWindow))
    }
}

/// A zero-cost NSView that reports the window it lands in, so the print sheet can anchor to the real
/// window hosting the toolbar. It reports from `viewDidMoveToWindow` (the one reliable attach point)
/// on the next runloop turn, so the binding never mutates state mid-view-update.
private struct HostWindowAnchor: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class ProbeView: NSView {
        var onMove: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMove?(window)
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onMove = { host in
            DispatchQueue.main.async {
                if window !== host { window = host }
            }
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}
}

/// The compact Share / Save / Print toolbar shown on the General Ledger day detail, in the deck's
/// monospaced button style. Share does not present the picker in place: a compose-style target
/// (Messages, Mail) attaches its session to the host window, so Share opens the stable Receipt window
/// for this day, which comes to front and auto-presents the picker anchored inside itself. Save… and
/// Print… run inline, since their panels host themselves.
struct ReceiptToolbar: View {
    let artifact: ReceiptArtifact
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            Button {
                // Mark this day as the one to auto-share, then open (or raise) its Receipt window and
                // activate the app so the window can become key from the accessory process.
                ReceiptWindowCoordinator.shared.pendingShareDay = artifact.dayEpoch
                openWindow(id: ReceiptWindow.id, value: artifact.dayEpoch)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Share").font(.system(.caption, design: .monospaced))
            }
            ReceiptSaveMenu(artifact: artifact)
            ReceiptPrintButton(artifact: artifact)
        }
    }
}
