import Foundation
import Testing

@testable import RDPKit

/// The print spool the printer backend writes documents to.
@Suite
struct PrintSpoolTests {
    static let pdf = Data("%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".utf8)

    private func contents(of scratch: ScratchFolder) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: scratch.url.path)) ?? []
    }

    @Test func aPDFWrittenInPartsArrivesWhole() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let spool = try #require(PrintSpool(folder: scratch.url))

        #expect(spool.open(7))
        #expect(spool.write(7, Self.pdf.prefix(10)))
        #expect(spool.write(7, Self.pdf.dropFirst(10)))
        #expect(spool.take().isEmpty)
        spool.close(7)

        let documents = spool.take()
        #expect(documents.count == 1)
        guard case .pdf(let url) = documents.first?.content else {
            Issue.record("Expected a PDF, got \(String(describing: documents.first))")
            return
        }
        #expect(try Data(contentsOf: url) == Self.pdf)
        #expect(documents.first?.size == UInt64(Self.pdf.count))
        #expect(spool.take().isEmpty)
    }

    @Test func aPDFMayStartAfterALittleLeadingData() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let spool = try #require(PrintSpool(folder: scratch.url))
        spool.open(1)
        spool.write(1, Data(repeating: 0x20, count: 500) + Self.pdf)
        spool.close(1)
        spool.open(2)
        spool.write(2, Data(repeating: 0x20, count: 1100) + Self.pdf)
        spool.close(2)

        let kinds = spool.take().map(\.content)
        guard case .pdf = kinds.first else {
            Issue.record("Expected a PDF first, got \(kinds)")
            return
        }
        #expect(kinds.last == .notPDF)
    }

    @Test func somethingOtherThanAPDFIsToldButNotKept() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let spool = try #require(PrintSpool(folder: scratch.url))
        spool.open(3)
        spool.write(3, Data("Hello, printer\r\n".utf8))
        spool.close(3)

        #expect(spool.take() == [RDPPrintedDocument(content: .notPDF, size: 16)])
        #expect(contents(of: scratch).isEmpty)
    }

    @Test func aDocumentPastTheLimitIsCutOffAndNotKept() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let spool = try #require(PrintSpool(folder: scratch.url, limit: 64))
        spool.open(4)
        #expect(spool.write(4, Self.pdf.prefix(40)))
        #expect(!spool.write(4, Data(count: 40)))
        #expect(!spool.write(4, Data(count: 1)))
        spool.close(4)

        #expect(spool.take() == [RDPPrintedDocument(content: .tooLarge, size: 64)])
        #expect(contents(of: scratch).isEmpty)
        #expect(RDPPrintedDocument.limit == 512 * 1024 * 1024)
    }

    @Test func documentsNotFinishedOrNotTakenGoWithTheSpool() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        var spool = PrintSpool(folder: scratch.url)
        spool?.open(5)
        spool?.write(5, Self.pdf)
        spool?.open(6)
        spool?.write(6, Self.pdf)
        spool?.close(6)
        #expect(contents(of: scratch).count == 2)

        spool = nil

        #expect(contents(of: scratch).isEmpty)
    }

    @Test func aJobThatIsArrivingCannotBeOpenedTwice() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let spool = try #require(PrintSpool(folder: scratch.url))
        #expect(spool.open(9))
        #expect(!spool.open(9))
        #expect(!spool.write(10, Self.pdf))
    }
}

/// Printing against the test server, which prints a PDF in three parts and
/// a short text to the client's printer (scripts/test-server/sample-screen.patch).
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(2)))
struct PrintingIntegrationTests {
    /// What the test server prints first.
    static let serverPDF = Data(
        ("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
            + "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n").utf8
    )

    private static func printerLines(after before: Int) -> [String] {
        FileClipboardIntegrationTests.serverLog().dropFirst(before).compactMap { line in
            line.range(of: "vistara-printer ").map { String(line[$0.upperBound...]) }
        }
    }

    @Test func theServersDocumentsArriveFromTheVistaraPrinter() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let before = FileClipboardIntegrationTests.serverLog().count
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.printing = RDPPrinting(folder: scratch.url.appendingPathComponent("Printing"))
        #expect(handle.connect(to: target) { _ in true } == .connected)
        defer { handle.disconnect() }

        var documents: [RDPPrintedDocument] = []
        let deadline = Date().addingTimeInterval(20)
        while documents.count < 2, Date() < deadline, handle.poll(timeoutMilliseconds: 100) {
            documents += handle.takePrinted()
        }

        #expect(handle.settingsGiven.deviceRedirection)
        let lines = Self.printerLines(after: before)
        #expect(lines.contains("announced name=Vistara driver=Microsoft Print to PDF"))
        #expect(lines.filter { $0.hasPrefix("wrote document=0 ") }.count == 3)
        #expect(documents.count == 2)
        guard case .pdf(let url) = documents.first?.content else {
            Issue.record("Expected a PDF first, got \(documents)")
            return
        }
        #expect(try Data(contentsOf: url) == Self.serverPDF)
        #expect(documents.first?.size == UInt64(Self.serverPDF.count))
        #expect(documents.last == RDPPrintedDocument(content: .notPDF, size: 16))
    }

    @Test func withoutPrintingNoPrinterIsOffered() throws {
        let before = FileClipboardIntegrationTests.serverLog().count
        let handle = try #require(SessionHandle())
        #expect(handle.connect(to: TestHost.target()) { _ in true } == .connected)
        defer { handle.disconnect() }

        var documents: [RDPPrintedDocument] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, handle.poll(timeoutMilliseconds: 100) {
            documents += handle.takePrinted()
        }

        // Neither a printer nor shared folders: the channel is not even loaded.
        #expect(!handle.settingsGiven.deviceRedirection)
        #expect(documents.isEmpty)
        #expect(!Self.printerLines(after: before).contains { $0.hasPrefix("announced") })
    }

    @Test func aSessionOffersThePrinterAndPublishesWhatIsPrinted() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        var configuration = TestHost.configuration
        configuration.printing = RDPPrinting(folder: scratch.url)
        let session = RDPSession(configuration: configuration, delegate: TestHost.delegate())
        session.start()
        var states = session.states.makeAsyncIterator()
        while let state = await states.next() {
            if case .connected = state { break }
        }

        var received: [RDPPrintedDocument] = []
        var printed = session.printedDocuments.makeAsyncIterator()
        while received.count < 2, let document = await printed.next() {
            received.append(document)
        }
        session.disconnect()
        while await states.next() != nil {}

        #expect(received.map(\.size) == [UInt64(Self.serverPDF.count), 16])
        #expect(received.last?.content == .notPDF)
    }
}
