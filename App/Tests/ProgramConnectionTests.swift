import AppKit
import Foundation
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// Making and opening connections that open a program (#156).
@Suite
@MainActor
struct ProgramConnectionTests {
    private static let word = Connection.Program(opens: .program, path: "||WINWORD", arguments: "/safe")

    @Test func theEditorSavesAProgramAndAsksForOneWhenChosen() throws {
        var draft = ConnectionDraft()
        draft.host = "apps01"
        draft.opens = .program
        #expect(draft.programProblem == "Enter the program as the computer publishes it, such as ||WINWORD.")
        #expect(!draft.isValid)

        draft.programPath = " ||WINWORD "
        draft.programArguments = "/safe"
        // Sizes don't apply to a program, so a bad one is no problem.
        draft.resolutionMode = .fixed
        draft.fixedWidth = "1"
        #expect(draft.isValid)
        let connection = try #require(draft.connection())
        #expect(connection.program == Self.word)

        // Back to the desktop, the program is kept for later.
        var back = ConnectionDraft(connection)
        #expect(back.opensProgram)
        back.opens = .desktop
        back.fixedWidth = "1920"
        #expect(try #require(back.connection()).program == Connection.Program(
            opens: .desktop, path: "||WINWORD", arguments: "/safe"
        ))
    }

    @Test func programsOnTheSameComputerUserAndGatewayShareASession() {
        var first = SessionTarget(name: "Word", host: "Apps01", port: 3389, username: "Alice", domain: "CORP")
        first.program = Self.word
        var second = SessionTarget(name: "Excel", host: "apps01", port: 3389, username: "alice", domain: "corp")
        second.program = Connection.Program(opens: .program, path: "||EXCEL")
        #expect(first.sharesSession(with: second))

        var otherUser = second
        otherUser.username = "bob"
        #expect(!first.sharesSession(with: otherUser))
        var throughGateway = second
        throughGateway.gateway = Connection.Gateway(usage: .always, host: "gw.example.com")
        #expect(!first.sharesSession(with: throughGateway))
    }

    @Test func answersArriveInTheOrderTheProgramsWereStarted() throws {
        var word = SessionTarget(name: "Word", host: "apps01", port: 3389)
        word.connectionID = UUID()
        word.program = Self.word
        var excel = word
        excel.name = "Excel"
        excel.connectionID = UUID()
        excel.program = Connection.Program(opens: .program, path: "||EXCEL")
        let wordID = try #require(word.connectionID)
        let model = SessionModel(target: word, credentialStore: InMemoryCredentialStore())
        model.beginPrograms()

        // Before the first answer, the session takes no more.
        model.startProgram(excel)
        #expect(model.programStarts.waiting.map(\.name) == ["Excel"])
        model.programAnswered(nil)
        #expect(model.programStarts.waiting.isEmpty)
        #expect(model.programStarts.awaitingAnswer.map(\.name) == ["Excel"])
        #expect(model.programStarts.awaitingIcon == [wordID])

        // An icon that comes before its program's answer waits for it.
        var icons: [UUID] = []
        model.onProgramIcon = { id, _ in icons.append(id) }
        model.programStarts.awaitingIcon = []
        model.programIconArrived(RDPImage(width: 1, height: 1, pixels: Data([0, 0, 0xFF, 0xFF])))
        #expect(icons.isEmpty)
        let again = ProgramStarts.Start(
            name: "Word", connectionID: word.connectionID, program: RDPProgram(path: "||WINWORD")
        )
        model.programStarts.awaitingAnswer.insert(again, at: 0)
        model.programAnswered(nil)
        #expect(icons == [wordID])

        model.programAnswered(.notPublished)
        let failure = ProgramFailure(failure: .notPublished, name: "Excel", connectionID: excel.connectionID)
        #expect(model.programFailure == failure)
        let excelID = try #require(excel.connectionID)
        #expect(!model.programStarts.running.contains(excelID))
    }

    @Test func theMessageSaysWhatToDoAboutAProgramThatDidNotStart() {
        let ended = DisconnectMessage.programFailed(
            .notPublished, program: "Word", computer: "apps01", sessionContinues: false
        )
        #expect(ended.title == "“Word” isn’t published on “apps01”")
        #expect(ended.action == .editConnection)
        #expect(ended.secondaryAction == .connect("Try Again"))

        let carriesOn = DisconnectMessage.programFailed(
            .notFound, program: "Word", computer: "apps01", sessionContinues: true
        )
        #expect(carriesOn.action == .dismiss)
        #expect(carriesOn.secondaryAction == .editConnection)
        let failed = DisconnectMessage.programFailed(
            .failed(code: 6), program: "Word", computer: "apps01", sessionContinues: false
        )
        #expect(failed.detail == "RemoteApp exec result 6")
    }

    @Test func aProgramsIconIsKeptForItsConnection() async throws {
        var word = Connection(name: "Word", host: "apps01")
        word.program = Self.word
        let (model, directory) = try await temporaryLibrary(Library(connections: [word]))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        await model.setProgramIcon(of: word.id, to: png)
        #expect(model.connection(word.id)?.programIcon == png)

        let reloaded = LibraryModel(store: ConnectionStore(directory: directory))
        await reloaded.load()
        #expect(reloaded.connection(word.id)?.programIcon == png)
    }
}

/// Opening program connections against the test server's RemoteApp host
/// (scripts/test-server/sample-screen.patch).
@Suite(.serialized)
@MainActor
struct ProgramOpeningTests {
    private static var lineCount: Int {
        guard let path = ProcessInfo.processInfo.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return 0 }
        return log.split(separator: "\n").count
    }

    private static func railLines(after before: Int) -> [String] {
        guard let path = ProcessInfo.processInfo.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").dropFirst(before).compactMap { line in
            line.range(of: "vistara-rail ").map { String(line[$0.upperBound...]) }
        }
    }

    private static func target(_ name: String, program: String, server: TestServer) -> SessionTarget {
        var target = server.target
        target.name = name
        target.connectionID = UUID()
        target.program = Connection.Program(opens: .program, path: program)
        return target
    }

    /// One account for every program connection to the server.
    private static func coordinator(_ server: TestServer, for targets: [SessionTarget]) throws -> SessionCoordinator {
        let store = InMemoryCredentialStore()
        let credentials = StoredCredentials(
            username: server.target.username, domain: server.target.domain, password: server.password
        )
        for target in targets { try store.save(credentials, for: target.credentialKey, label: "Test") }
        return SessionCoordinator(credentialStore: store, trustStore: temporaryTrustStore())
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func openingAProgramShowsThePanelThenItsWindowAndKeepsItsIcon() async throws {
        let server = try #require(TestServer.current)
        let notepad = Self.target("Notepad", program: "||vistara-notepad", server: server)
        let coordinator = try Self.coordinator(server, for: [notepad])
        var icons: [(UUID, Data)] = []
        coordinator.programIconArrived = { id, png in icons.append((id, png)) }

        let controller = coordinator.open(notepad)
        let panel = controller.window
        #expect(panel.isVisible)
        #expect(!panel.styleMask.contains(.resizable))
        #expect(panel.tabbingMode == .disallowed)
        #expect(panel.contentLayoutRect.size == SessionWindowController.panelContentSize)

        await waitUntil("the certificate question is open") { controller.model.pendingCertificate != nil }
        controller.model.answerCertificate(trust: true)
        await waitUntil("the program's window is shown") {
            controller.model.programs?.controllers[0x100]?.window.isVisible == true
        }
        await waitUntil("the panel steps aside") { !panel.isVisible }
        await waitUntil("the program's icon arrived") { !icons.isEmpty }
        #expect(icons.first?.0 == notepad.connectionID)
        #expect(icons.first.flatMap { NSImage(data: $0.1) }?.size == NSSize(width: 16, height: 16))

        coordinator.disconnect(controller.model)
        await waitUntil("the session has ended") { !controller.model.isLive }
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func aProgramTheComputerDoesNotPublishIsSaidInThePanel() async throws {
        let server = try #require(TestServer.current)
        let missing = Self.target("Missing", program: "||not-published", server: server)
        let coordinator = try Self.coordinator(server, for: [missing])
        var edited: UUID?
        coordinator.editConnection = { edited = $0 }

        let controller = coordinator.open(missing)
        let model = controller.model
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session ended because the program did not start") {
            !model.isLive && model.programFailure != nil
        }

        #expect(model.programFailure?.failure == .notPublished)
        #expect(controller.window.isVisible)
        let message = try #require(model.programFailureMessage)
        #expect(message.title == "“Missing” isn’t published on “\(server.target.host)”")
        #expect(message.action == .editConnection)
        model.editConnection()
        #expect(edited == missing.connectionID)
        controller.window.close()
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func twoProgramConnectionsToOneComputerShareASession() async throws {
        let server = try #require(TestServer.current)
        let before = Self.lineCount
        let notepad = Self.target("Notepad", program: "||vistara-notepad", server: server)
        let calculator = Self.target("Calculator", program: "||vistara-calc", server: server)
        let coordinator = try Self.coordinator(server, for: [notepad, calculator])

        let controller = coordinator.open(notepad)
        // Opened before the first program has started: it waits its turn.
        #expect(coordinator.open(calculator) === controller)
        await waitUntil("the certificate question is open") { controller.model.pendingCertificate != nil }
        controller.model.answerCertificate(trust: true)
        await waitUntil("both programs' windows are shown") {
            controller.model.programs?.controllers[0x100] != nil && controller.model.programs?.controllers[0x200] != nil
        }

        // The answers come on another channel than the windows.
        await waitUntil("both programs were answered") { controller.model.programStarts.awaitingAnswer.isEmpty }
        #expect(coordinator.sessionWindows.count == 1)
        let lines = Self.railLines(after: before)
        #expect(lines.filter { $0.hasPrefix("handshake ") }.count == 1)
        #expect(lines.contains("exec program=||vistara-calc arguments="))
        // Opening one that runs brings its windows forward instead.
        #expect(coordinator.open(calculator) === controller)
        #expect(controller.model.programStarts.awaitingAnswer.isEmpty && controller.model.programStarts.waiting.isEmpty)

        coordinator.disconnect(controller.model)
        await waitUntil("the session has ended") { !controller.model.isLive }
    }
}
