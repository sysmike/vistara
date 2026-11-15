import AppKit
import Foundation
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// Program connections in the editor, the library, and the Connecting panel,
/// rendered for review (#156).
@Suite(.serialized)
@MainActor
struct ProgramScreenshotTests {
    private static var word: Connection {
        var word = Connection(name: "Word", host: "apps01.example.com")
        word.username = "alice"
        word.program = Connection.Program(opens: .program, path: "||WINWORD")
        return word
    }

    private static func panelModel(phase: SessionModel.Phase) -> SessionModel {
        var target = SessionTarget(connection: word)
        target.connectionID = word.id
        return SessionModel(target: target, credentialStore: InMemoryCredentialStore(), phase: phase)
    }

    @Test(arguments: [false, true])
    func editorOpeningAProgram(dark: Bool) async throws {
        let view = ConnectionEditor(draft: ConnectionDraft(Self.word), folders: []) { _ in }
        let bytes = try await Screenshots.write(
            view, size: NSSize(width: 480, height: 760), name: dark ? "editor-program-dark" : "editor-program",
            dark: dark
        )
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func libraryWithAProgram(dark: Bool) async throws {
        var library = SampleLibrary.library
        var word = Self.word
        word.programIcon = Self.sampleIcon()
        var excel = Connection(name: "Excel", host: "apps01.example.com")
        excel.program = Connection.Program(opens: .program, path: "||EXCEL")
        library.connections += [word, excel]
        let (model, _) = try await temporaryLibrary(library)
        let bytes = try await Screenshots.write(
            ConnectionsView(model: model) { _, _ in }, size: NSSize(width: 780, height: 460),
            name: dark ? "library-program-dark" : "library-program", dark: dark,
            frame: .window(title: "Connections")
        )
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func connectingPanel(dark: Bool) async throws {
        let model = Self.panelModel(phase: .connecting)
        let bytes = try await Screenshots.write(
            SessionContentView(model: model), size: SessionWindowController.panelContentSize,
            name: dark ? "program-connecting-dark" : "program-connecting", dark: dark
        )
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func programNotPublished(dark: Bool) async throws {
        let model = Self.panelModel(phase: .disconnected(.userRequested))
        model.programFailure = ProgramFailure(failure: .notPublished, name: "Word", connectionID: Self.word.id)
        model.onEditConnection = {}
        let bytes = try await Screenshots.write(
            SessionContentView(model: model), size: SessionWindowController.panelContentSize,
            name: dark ? "program-not-published-dark" : "program-not-published", dark: dark
        )
        #expect(bytes > 0)
    }

    /// A blue page with a white fold, as a word processor's icon might be.
    private static func sampleIcon() -> Data? {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 2), xRadius: 4, yRadius: 4).fill()
            NSColor.white.setFill()
            NSRect(x: 9, y: 9, width: 14, height: 3).fill()
            NSRect(x: 9, y: 15, width: 14, height: 3).fill()
            NSRect(x: 9, y: 21, width: 10, height: 3).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
