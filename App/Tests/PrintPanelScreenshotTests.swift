import AppKit
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// The real print panel on a session window, for its screenshots. It looks
/// for printers on the network, and macOS asks once whether Vistara may, in a
/// dialog that takes the focus from every window after it. So it runs only
/// when asked (VISTARA_PRINT_PANEL=1), which CI does after all other tests.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["VISTARA_PRINT_PANEL"] == "1", "Shows the real print panel")
)
@MainActor
struct PrintPanelScreenshotTests {
    @Test(arguments: [false, true])
    func aDocumentOpensThePrintPanelOnTheWindow(dark: Bool) async throws {
        let model = SessionModel(
            target: SessionTarget(name: "Build Server", host: "build01.example.com", port: 3389),
            credentialStore: InMemoryCredentialStore()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let printer = SessionPrinter(window: window, model: model)
        printer.start()

        let printing = model.printQueue.makePrinting()
        let url = printing.folder.appendingPathComponent("job-1")
        try PrintingTests.samplePDF().write(to: url)
        model.printQueue.add(RDPPrintedDocument(content: .pdf(url), size: 1))

        await waitUntil("the print panel is on the window") { window.attachedSheet != nil }
        let panel = try #require(window.attachedSheet)
        panel.appearance = window.appearance
        // The preview draws over a few frames.
        try await Task.sleep(for: .seconds(1))
        let bytes = try await Screenshots.writeAsShown(panel, name: dark ? "print-panel-dark" : "print-panel")
        #expect(bytes > 0)

        window.endSheet(panel, returnCode: .cancel)
        await waitUntil("the panel is gone and nothing waits") { model.printQueue.next == nil }
        panel.orderOut(nil)
    }
}
