import AppKit
import PDFKit
import RDPKit
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// Printing on the Mac what the remote computer prints (docs/DESIGN.md, Printing).
@Suite(.serialized)
@MainActor
struct PrintingTests {
    /// A one-page PDF with a little text, as the remote computer could print.
    static func samplePDF() -> Data {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        view.textContainerInset = NSSize(width: 48, height: 48)
        view.backgroundColor = .white
        let title = NSAttributedString(
            string: "Quarterly Report\n",
            attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.black]
        )
        let body = NSAttributedString(
            string: "Sales grew in every region this quarter.",
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        )
        view.textStorage?.setAttributedString(title)
        view.textStorage?.append(body)
        return view.dataWithPDF(inside: view.bounds)
    }

    private func makeModel(name: String = "Build Server") -> SessionModel {
        SessionModel(
            target: SessionTarget(name: name, host: "build01.example.com", port: 3389),
            credentialStore: InMemoryCredentialStore()
        )
    }

    private func makeWindow(dark: Bool = false) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Puts a document in the queue as RDPKit hands it over: a file in the print folder.
    private func deliver(_ data: Data, to model: SessionModel) throws -> URL {
        let printing = model.printQueue.makePrinting()
        let url = printing.folder.appendingPathComponent("job-1")
        try data.write(to: url)
        model.printQueue.add(RDPPrintedDocument(content: .pdf(url), size: UInt64(data.count)))
        return url
    }

    // MARK: The setting

    @Test
    func printingIsOnUnlessTurnedOff() throws {
        #expect(Connection(name: "PC", host: "pc").printsOnThisMac)
        #expect(NewConnectionDefaults().printsOnThisMac)
        let saved = Data(#"{"sharesClipboard":true}"#.utf8)
        #expect(try JSONDecoder().decode(NewConnectionDefaults.self, from: saved).printsOnThisMac)
        let older = Data(#"{"id":"6F1D2B44-8D4A-4C8E-9A57-3E1F5B0C7D21","name":"PC","host":"pc"}"#.utf8)
        #expect(try JSONDecoder().decode(Connection.self, from: older).printsOnThisMac)

        var defaults = NewConnectionDefaults()
        defaults.printsOnThisMac = false
        #expect(!ConnectionDraft(defaults: defaults).printsOnThisMac)
        var connection = Connection(name: "PC", host: "pc")
        connection.printsOnThisMac = false
        #expect(!SessionTarget(connection: connection).printsOnThisMac)
        #expect(ConnectionDraft(connection).connection()?.printsOnThisMac == false)
    }

    // MARK: The queue

    @Test
    func documentsWaitTheirTurnAndGoOnceShown() throws {
        let model = makeModel()
        let first = try deliver(Self.samplePDF(), to: model)
        model.printQueue.add(RDPPrintedDocument(content: .notPDF, size: 16))
        model.printQueue.add(RDPPrintedDocument(content: .tooLarge, size: RDPPrintedDocument.limit))

        let next = try #require(model.printQueue.next)
        #expect(next.content == .document(first))
        model.printQueue.finish(next)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(model.printQueue.next?.content == .refused(tooLarge: false))
        model.printQueue.finish(try #require(model.printQueue.next))
        #expect(model.printQueue.next?.content == .refused(tooLarge: true))

        // The session ends: nothing waits, and its folder goes.
        let folder = try #require(model.printQueue.folder)
        model.printQueue.end()
        #expect(model.printQueue.next == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test
    func refusalsSayWhatHappenedAndWhatToDo() {
        #expect(PrintRefusal.title(name: "Build Server") == "A document from “Build Server” can’t be printed")
        #expect(PrintRefusal.explanation(tooLarge: true) == "It’s larger than 512 MB, the most Vistara takes.")
        #expect(PrintRefusal.explanation(tooLarge: false).contains("“Vistara”"))
    }

    // MARK: The print panel

    @Test(.timeLimit(.minutes(1)))
    func aPrintedDocumentCanBeSavedAsTheSameDocument() async throws {
        let model = makeModel()
        let window = makeWindow()
        defer { window.close() }
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-print-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: saved) }
        let printer = SessionPrinter(window: window, model: model)
        printer.showsPrintPanel = false
        printer.makePrintInfo = {
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = saved
            return info
        }
        printer.start()

        let source = try deliver(Self.samplePDF(), to: model)

        await waitUntil("the document is saved and the queue is empty") {
            FileManager.default.fileExists(atPath: saved.path) && model.printQueue.next == nil
        }
        let document = try #require(PDFDocument(url: saved))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("Quarterly Report") == true)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func aDocumentOpensThePrintPanelOnTheWindowAndARefusalAnAlert() async throws {
        let model = makeModel()
        let window = makeWindow()
        defer { window.close() }
        let printer = SessionPrinter(window: window, model: model)
        printer.start()

        _ = try deliver(Self.samplePDF(), to: model)
        model.printQueue.add(RDPPrintedDocument(content: .notPDF, size: 16))

        await waitUntil("the print panel is on the window") { window.attachedSheet != nil }
        let panel = try #require(window.attachedSheet)
        window.endSheet(panel, returnCode: .cancel)
        await waitUntil("the alert follows") {
            window.attachedSheet != nil && window.attachedSheet !== panel
        }
        #expect(model.printQueue.next?.content == .refused(tooLarge: false))
        if let alert = window.attachedSheet { window.endSheet(alert) }
        await waitUntil("nothing waits any more") { model.printQueue.next == nil && window.attachedSheet == nil }
    }

    // MARK: Against the test server

    /// The whole way: the test server prints a PDF and a text to the session's
    /// printer, the PDF is saved from the window's printer, and the text is
    /// refused with an alert on the window.
    @Test(.enabled(if: TestServer.isFreeRDPTestServer), .timeLimit(.minutes(1)))
    func whatTheServerPrintsComesOutOnTheWindow() async throws {
        let server = try #require(TestServer.current)
        let model = SessionModel(target: server.address, credentialStore: try server.storeWithCredentials())
        let controller = SessionWindowController(model: model)
        defer { controller.window.close() }
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-print-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: saved) }
        let printer = try #require(controller.printer)
        printer.showsPrintPanel = false
        printer.makePrintInfo = {
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = saved
            return info
        }
        controller.show()

        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.trustOnce)
        await waitUntil("the PDF is saved and the refusal is on the window", within: .seconds(30)) {
            FileManager.default.fileExists(atPath: saved.path) && controller.window.attachedSheet != nil
        }

        let document = try #require(PDFDocument(url: saved))
        #expect(document.pageCount == 1)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 200, height: 200))
        #expect(model.printQueue.next?.content == .refused(tooLarge: false))
        if let alert = controller.window.attachedSheet { controller.window.endSheet(alert) }
        await waitUntil("nothing waits any more") { model.printQueue.next == nil }
        let folder = try #require(model.printQueue.folder)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Screenshots

    @Test(arguments: [false, true])
    func screenshotOfThePrintPanel(dark: Bool) async throws {
        let model = makeModel()
        let window = makeWindow(dark: dark)
        defer { window.close() }
        let printer = SessionPrinter(window: window, model: model)
        printer.start()
        _ = try deliver(Self.samplePDF(), to: model)
        await waitUntil("the print panel is on the window") { window.attachedSheet != nil }
        let panel = try #require(window.attachedSheet)
        panel.appearance = window.appearance
        // The preview draws over a few frames.
        try await Task.sleep(for: .seconds(1))

        let bytes = try await Screenshots.write(panel, name: dark ? "print-panel-dark" : "print-panel")
        #expect(bytes > 0)
        window.endSheet(panel, returnCode: .cancel)
        await waitUntil("the panel is gone") { model.printQueue.next == nil }
    }

    @Test(arguments: [false, true])
    func screenshotOfTheEditorWithPrinting(dark: Bool) async throws {
        let connection = SampleLibrary.library.connections[0]
        let view = ConnectionEditor(draft: ConnectionDraft(connection), folders: []) { _ in }
        let name = dark ? "editor-printing-dark" : "editor-printing"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 960), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
