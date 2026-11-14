import AppKit
import os
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// Copying files through the clipboard in the app (docs/DESIGN.md, Copying
/// files), with a stand-in for the session's fetch.
@Suite(.serialized)
@MainActor
struct FileClipboardTests {
    /// What the bridge sent to the session.
    private final class Sent {
        var texts: [String] = []
        var offers: [RDPLocalFileOffer] = []
    }

    /// Counts fetches and writes what they fetch: a file holds "x".
    private final class FakeFetch: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        /// How long each fetch takes; it ends early when cancelled.
        let delay: Duration

        init(delay: Duration = .zero) {
            self.delay = delay
        }

        var calls: Int { count.withLock { $0 } }

        var fetch: RemoteFilePaste.Fetch {
            { [self] items, _, folder, progress in
                count.withLock { $0 += 1 }
                progress(RDPFileFetchProgress(bytesReceived: 0, bytesExpected: 2_000_000, filesDone: 0, fileCount: 2))
                try await Task.sleep(for: delay)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try items.map { item in
                    let url = folder.appendingPathComponent(item.path)
                    if item.isFolder {
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    } else {
                        try Data("x".utf8).write(to: url)
                    }
                    return url
                }
            }
        }
    }

    private struct Fixture {
        let bridge: ClipboardBridge
        let pasteboard: NSPasteboard
        let sent: Sent
        let files: RemoteFilePaste
    }

    static let remote = RDPRemoteFiles(files: [
        RDPClipboardFile(path: "Report.pdf", size: 1_000_000, isFolder: false),
        RDPClipboardFile(path: "Photos", size: 0, isFolder: true),
        RDPClipboardFile(path: "Photos/Beach.jpg", size: 1_000_000, isFolder: false)
    ])

    private func make(fetch: FakeFetch = FakeFetch(), inFront: @escaping () -> Bool = { true }) -> Fixture {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.sysmike.vistara.tests.\(UUID().uuidString)"))
        let sent = Sent()
        let files = RemoteFilePaste(computerName: "Build Server", fetch: fetch.fetch)
        files.showProgress = { _ in }
        let bridge = ClipboardBridge(pasteboard: pasteboard, send: { events in
            for event in events {
                switch event {
                case .clipboardText(let text): sent.texts.append(text)
                case .clipboardFiles(let offer): sent.offers.append(offer)
                default: break
                }
            }
        }, isInFront: inFront, files: files)
        return Fixture(bridge: bridge, pasteboard: pasteboard, sent: sent, files: files)
    }

    private func makeFiles() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Folder"), withIntermediateDirectories: true
        )
        try Data("Quarterly report\n".utf8).write(to: folder.appendingPathComponent("Report.txt"))
        try Data("Inside\n".utf8).write(to: folder.appendingPathComponent("Folder/Inner.txt"))
        return folder
    }

    private func pastedURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Mac to remote computer

    @Test
    func filesCopiedOnTheMacAreOfferedInPlaceOfText() async throws {
        let fixture = make()
        let folder = try makeFiles()
        defer { try? FileManager.default.removeItem(at: folder) }
        fixture.pasteboard.clearContents()
        fixture.pasteboard.writeObjects([
            folder.appendingPathComponent("Report.txt") as NSURL, folder.appendingPathComponent("Folder") as NSURL
        ])

        fixture.bridge.checkMacClipboard()
        await fixture.bridge.waitUntilOffered()

        #expect(fixture.sent.offers.map { $0.files.map(\.path) } == [["Report.txt", "Folder", "Folder/Inner.txt"]])
        #expect(fixture.sent.texts.isEmpty)
    }

    @Test
    func concealedFilesStayOnTheMac() async throws {
        let fixture = make()
        let folder = try makeFiles()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = NSPasteboardItem()
        item.setString(folder.appendingPathComponent("Report.txt").absoluteString, forType: .fileURL)
        item.setString("", forType: ClipboardBridge.concealed)
        fixture.pasteboard.clearContents()
        fixture.pasteboard.writeObjects([item])

        fixture.bridge.checkMacClipboard()
        await fixture.bridge.waitUntilOffered()

        #expect(fixture.sent.offers.isEmpty)
    }

    @Test
    func withoutCopyFilesCopiedFilesGoAsTheirNames() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.sysmike.vistara.tests.\(UUID().uuidString)"))
        var sent: [RDPInputEvent] = []
        let bridge = ClipboardBridge(pasteboard: pasteboard, send: { sent += $0 }, isInFront: { true })
        let folder = try makeFiles()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = NSPasteboardItem()
        item.setString(folder.appendingPathComponent("Report.txt").absoluteString, forType: .fileURL)
        item.setString("Report.txt", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        bridge.checkMacClipboard()
        await bridge.waitUntilOffered()

        #expect(sent == [.clipboardText("Report.txt")])
    }

    // MARK: Remote computer to Mac

    @Test
    func remoteFilesAreFetchedOnlyWhenPasted() throws {
        let fetch = FakeFetch()
        let fixture = make(fetch: fetch)
        defer { fixture.bridge.stop() }

        fixture.bridge.receive(Self.remote)

        // One item for each copied item, nothing fetched yet.
        #expect(fixture.pasteboard.pasteboardItems?.count == 2)
        #expect(fetch.calls == 0)
        let urls = pastedURLs(from: fixture.pasteboard)
        #expect(urls.map(\.lastPathComponent) == ["Report.pdf", "Photos"])
        #expect(urls.allSatisfy { $0.path.hasPrefix(fixture.files.folder.path) })
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
        // Pasting again does not fetch again.
        _ = pastedURLs(from: fixture.pasteboard)
        #expect(fetch.calls == 1)
        // Not offered back to the remote computer.
        fixture.bridge.checkMacClipboard()
        #expect(fixture.sent.offers.isEmpty && fixture.sent.texts.isEmpty)
    }

    @Test
    func textCopiedWithTheFilesStaysWithThem() {
        let fixture = make()
        defer { fixture.bridge.stop() }

        fixture.bridge.receive(Self.remote)
        fixture.bridge.receive("Report.pdf")

        #expect(fixture.pasteboard.pasteboardItems?.count == 2)
        #expect(fixture.pasteboard.string(forType: .string) == "Report.pdf")
        // The remote computer copies something else: its files are gone.
        fixture.bridge.receive(RDPRemoteFiles(files: []))
        #expect(!fixture.files.hasFiles)
        #expect(fixture.pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test
    func fetchedFilesAreRemovedWhenSomethingElseIsCopied() throws {
        let fixture = make()
        defer { fixture.bridge.stop() }
        fixture.bridge.receive(Self.remote)
        let urls = pastedURLs(from: fixture.pasteboard)
        #expect(FileManager.default.fileExists(atPath: urls[0].path))

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("something else", forType: .string)
        fixture.bridge.checkMacClipboard()

        #expect(!fixture.files.hasFiles)
        #expect(!FileManager.default.fileExists(atPath: fixture.files.folder.path))
    }

    @Test
    func endingTheSessionTakesTheFilesOffTheClipboard() throws {
        let fixture = make()
        fixture.bridge.receive(Self.remote)
        let urls = pastedURLs(from: fixture.pasteboard)
        #expect(!urls.isEmpty)

        fixture.bridge.stop()

        #expect(fixture.pasteboard.pasteboardItems?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: fixture.files.folder.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowPasteShowsItsProgressAndCanBeCancelled() throws {
        let fetch = FakeFetch(delay: .seconds(30))
        let fixture = make(fetch: fetch)
        defer { fixture.bridge.stop() }
        fixture.files.progressDelay = .milliseconds(200)
        var shown: [String] = []
        fixture.files.showProgress = { paste in
            guard let paste else { return }
            shown.append(paste.title)
            paste.cancel()
        }
        fixture.bridge.receive(Self.remote)

        let started = ContinuousClock.now
        let urls = pastedURLs(from: fixture.pasteboard)

        #expect(urls.isEmpty)
        #expect(shown == ["Copying 2 items from “Build Server”"])
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1)))
    func aPasteUnderWayKeepsItsFilesWhenTheRemoteComputerCopiesSomethingElse() throws {
        let fixture = make(fetch: FakeFetch(delay: .milliseconds(600)))
        defer { fixture.bridge.stop() }
        fixture.files.progressDelay = .milliseconds(100)
        // Halfway through, the remote computer copies something else.
        fixture.files.showProgress = { paste in
            if paste != nil { fixture.files.replace(with: nil) }
        }
        fixture.bridge.receive(Self.remote)

        let urls = pastedURLs(from: fixture.pasteboard)

        #expect(urls.map(\.lastPathComponent) == ["Report.pdf", "Photos"])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!fixture.files.hasFiles)
    }

    @Test
    func progressSaysWhatIsCopiedAndHowMuch() {
        let one = FilePasteProgress(computerName: "Build Server", itemNames: ["Report.pdf"]) {}
        #expect(one.title == "Copying “Report.pdf” from “Build Server”")
        #expect(one.detail == "Preparing…")
        one.progress = RDPFileFetchProgress(
            bytesReceived: 500_000, bytesExpected: 2_000_000, filesDone: 0, fileCount: 1
        )
        let half = Int64(500_000).formatted(.byteCount(style: .file))
        let expected = "\(half) of \(Int64(2_000_000).formatted(.byteCount(style: .file)))"
        #expect(one.detail == expected)
        let several = FilePasteProgress(computerName: "Build Server", itemNames: ["a", "b", "c"]) {}
        #expect(several.title == "Copying 3 items from “Build Server”")
    }
}
