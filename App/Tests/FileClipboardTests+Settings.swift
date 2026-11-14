import AppKit
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// The Copy files setting, and screenshots of it and of a paste.
extension FileClipboardTests {
    // MARK: Settings

    @Test
    func copyingFilesIsOffUnlessChosen() throws {
        #expect(!Connection(name: "PC", host: "pc").copiesFiles)
        #expect(!NewConnectionDefaults().copiesFiles)
        let saved = Data(#"{"sharesClipboard":true}"#.utf8)
        let older = try JSONDecoder().decode(NewConnectionDefaults.self, from: saved)
        #expect(!older.copiesFiles)

        var defaults = NewConnectionDefaults()
        defaults.copiesFiles = true
        let draft = ConnectionDraft(defaults: defaults)
        #expect(draft.copiesFiles)
    }

    @Test
    func copyingFilesNeedsTheSharedClipboard() {
        var connection = Connection(name: "PC", host: "pc")
        connection.copiesFiles = true
        let target = SessionTarget(connection: connection)
        let desktop = DesktopSize(width: 1280, height: 800, scalePercent: 100)
        #expect(target.configuration(desktop: desktop).copiesFiles)
        connection.sharesClipboard = false
        #expect(!SessionTarget(connection: connection).configuration(desktop: desktop).copiesFiles)

        // The editor keeps the choice while the clipboard is not shared.
        var draft = ConnectionDraft(connection)
        #expect(draft.copiesFiles)
        draft.sharesClipboard = true
        let saved = draft.connection()
        #expect(saved?.copiesFiles == true && saved?.sharesClipboard == true)
    }

    // MARK: Screenshots

    @Test(arguments: [false, true])
    func screenshotOfTheEditorWithCopyFiles(dark: Bool) async throws {
        var connection = SampleLibrary.library.connections[0]
        connection.copiesFiles = true
        let view = ConnectionEditor(draft: ConnectionDraft(connection), folders: []) { _ in }
        let name = dark ? "editor-copy-files-dark" : "editor-copy-files"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 960), name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func screenshotOfAPasteInProgress(dark: Bool) async throws {
        let paste = FilePasteProgress(computerName: "Build Server", itemNames: ["Quarterly Report.pdf"]) {}
        paste.progress = RDPFileFetchProgress(
            bytesReceived: 18_400_000, bytesExpected: 42_000_000, filesDone: 0, fileCount: 1
        )
        let view = FilePasteProgressView(paste: paste)
        let name = dark ? "file-paste-progress-dark" : "file-paste-progress"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 380, height: 120), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
