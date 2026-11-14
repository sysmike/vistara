import AppKit
import Observation
import PDFKit

/// Shows what a session's remote computer printed, one item at a time, as a
/// sheet on its window (docs/DESIGN.md, Printing): a PDF in the Mac's print
/// panel, with a preview, every printer, and the PDF menu to save it; and
/// what can't be printed as an alert.
@MainActor
final class SessionPrinter: NSObject {
    private let window: NSWindow
    private let model: SessionModel
    /// The item on screen, until its sheet ends.
    private var shown: PrintQueue.Item?
    /// What the print panel starts with. Tests print to a file instead.
    var makePrintInfo: () -> NSPrintInfo = { (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo() }
    /// Whether the print panel is shown. Tests print without it.
    var showsPrintPanel = true

    init(window: NSWindow, model: SessionModel) {
        self.window = window
        self.model = model
        super.init()
    }

    /// Shows what is printed from now on, starting with what waits.
    func start() {
        withObservationTracking {
            _ = model.printQueue.next
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.showNext()
                self?.start()
            }
        }
        showNext()
    }

    private func showNext() {
        guard shown == nil, let item = model.printQueue.next else { return }
        shown = item
        // Printing is the user's to start; the remote computer only asked.
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        switch item.content {
        case .document(let url):
            showPrintPanel(for: url, item: item)
        case .refused(let tooLarge):
            showRefusal(tooLarge: tooLarge, item: item)
        }
    }

    private func showPrintPanel(for url: URL, item: PrintQueue.Item) {
        // Read into memory, so the file can go now whatever happens next.
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard let data, let document = PDFDocument(data: data),
            let operation = document.printOperation(
                for: makePrintInfo(), scalingMode: .pageScaleToFit, autoRotate: true
            )
        else {
            showRefusal(tooLarge: false, item: item)
            return
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        operation.jobTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Document from “\(model.target.name)”"
        operation.showsPrintPanel = showsPrintPanel
        operation.showsProgressPanel = showsPrintPanel
        operation.printPanel.options.formUnion([.showsPreview, .showsCopies, .showsPageRange, .showsPaperSize])
        operation.runModal(
            for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        finishShown()
    }

    private func showRefusal(tooLarge: Bool, item: PrintQueue.Item) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = PrintRefusal.title(name: model.target.name)
        alert.informativeText = PrintRefusal.explanation(tooLarge: tooLarge)
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishShown() }
        }
    }

    private func finishShown() {
        guard let item = shown else { return }
        shown = nil
        model.printQueue.finish(item)
        showNext()
    }
}
