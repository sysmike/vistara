import AppKit
import Foundation
import Testing
import VistaraCore
@testable import Vistara

/// This Display or All Displays, per connection (docs/DESIGN.md, Multiple
/// displays; #113).
@Suite
@MainActor
struct DisplaysChoiceTests {
    @Test
    func theEditorExplainsAllDisplays() throws {
        #expect(ConnectionEditor.displaysExplanation(allDisplays: false, separateSpaces: true) == nil)
        let spanning = try #require(ConnectionEditor.displaysExplanation(allDisplays: true, separateSpaces: true))
        #expect(spanning.contains("full screen"))
        #expect(!spanning.contains("Spaces"))
        let oneDisplay = try #require(ConnectionEditor.displaysExplanation(allDisplays: true, separateSpaces: false))
        #expect(oneDisplay.contains("Displays have separate Spaces"))
        #expect(oneDisplay.contains("Desktop & Dock"))
    }

    @Test
    func theChoiceGoesFromTheConnectionToTheSessionAndBack() throws {
        var connection = Connection(name: "Build Server", host: "build01")
        connection.usesAllDisplays = true
        #expect(SessionTarget(connection: connection).usesAllDisplays)
        let draft = ConnectionDraft(connection)
        #expect(draft.usesAllDisplays)
        #expect(try #require(draft.connection()).usesAllDisplays)
        #expect(!SessionTarget(connection: Connection(name: "A", host: "a")).usesAllDisplays)
    }

    @Test
    func theImportReportSaysWhenAFileChoosesDisplays() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Office PC.rdp")
        try Data("full address:s:office\nuse multimon:i:1\nselectedmonitors:s:0,2\n".utf8).write(to: url)
        let (model, _) = try await temporaryLibrary()

        let report = await model.importRDPFiles([url])
        #expect(report.chosenDisplays == ["Office PC"])
        #expect(report.sentences.contains("“Office PC” names particular displays; Vistara uses all of them."))
        #expect(model.library.connections.first?.usesAllDisplays == true)
    }

    @Test(arguments: [false, true])
    func screenshotOfTheEditorWithAllDisplays(dark: Bool) async throws {
        var draft = ConnectionDraft(SampleLibrary.library.connections[0])
        draft.usesAllDisplays = true
        let view = ConnectionEditor(draft: draft, folders: []) { _ in }
        let name = dark ? "editor-all-displays-dark" : "editor-all-displays"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 700), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
