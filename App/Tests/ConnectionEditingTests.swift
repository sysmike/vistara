import Foundation
import Testing
import VistaraCore
@testable import Vistara

@Suite
struct ConnectionDraftTests {
    private func draft(host: String = "build01.example.com", port: String = "3389") -> ConnectionDraft {
        var draft = ConnectionDraft()
        draft.host = host
        draft.port = port
        return draft
    }

    @Test
    func aComputerIsAllANewConnectionNeeds() throws {
        let connection = try #require(draft().connection())
        #expect(connection.name == "build01.example.com")
        #expect(connection.host == "build01.example.com")
        #expect(connection.port == 3389)
        #expect(connection.requiresNLA)
    }

    @Test
    func theHostIsCheckedAsYouType() {
        let problems: [String: String?] = [
            "": "Enter the computer’s name or address.",
            "   ": "Enter the computer’s name or address.",
            "rdp://build01": "Enter only the computer’s name, without “rdp://” or a path.",
            "build01/desk": "Enter only the computer’s name, without “rdp://” or a path.",
            "build 01": "A computer’s name can’t contain spaces.",
            "build01:3390": "Enter the port in the Port field.",
            " build01.example.com ": nil,
            "10.0.4.17": nil,
            "fe80::1": nil
        ]
        for (host, problem) in problems {
            #expect(draft(host: host).hostProblem == problem, "\(host)")
        }
    }

    @Test
    func thePortMustBeANumberThatCanBeAPort() {
        for port in ["0", "65536", "rdp", "", "-1", "3389.5"] {
            #expect(draft(port: port).portProblem == "Enter a port from 1 to 65535.", "\(port)")
            #expect(draft(port: port).connection() == nil, "\(port)")
        }
        #expect(draft(port: " 3390 ").connection()?.port == 3390)
    }

    @Test
    func aFixedSizeMustBeOneTheProtocolAllows() {
        var fixed = draft()
        fixed.resolutionMode = .fixed
        fixed.fixedWidth = "100"
        #expect(fixed.sizeProblem == "Enter a width and height from 200 to 8192.")
        fixed.fixedWidth = "2560"
        fixed.fixedHeight = "1440"
        #expect(fixed.sizeProblem == nil)
        #expect(fixed.connection()?.fixedWidth == 2560)
        // Sizes only matter for a fixed size.
        var matching = draft()
        matching.fixedWidth = "abc"
        #expect(matching.sizeProblem == nil)
    }

    @Test
    func aDomainCanBeTypedWithTheUserName() {
        var typed = draft()
        typed.username = "CORP\\alice"
        #expect(typed.connection()?.username == "alice")
        #expect(typed.connection()?.domain == "CORP")
        typed.domain = "EXAMPLE"
        #expect(typed.connection()?.domain == "EXAMPLE")
    }

    @Test
    func editingKeepsWhatTheEditorDoesNotShow() throws {
        var original = Connection(name: "Build Server", host: "build01")
        original.tags = ["prod"]
        original.isFavorite = true
        original.lastConnectedAt = Date(timeIntervalSince1970: 1_800_000_000)
        original.additionalRDPSettings = ["audiocapturemode:i:1"]
        var edited = ConnectionDraft(original)
        #expect(!edited.isNew)
        edited.host = "build02"
        let saved = try #require(edited.connection())
        #expect(saved.id == original.id)
        #expect(saved.host == "build02")
        #expect(saved.tags == ["prod"])
        #expect(saved.isFavorite)
        #expect(saved.lastConnectedAt == original.lastConnectedAt)
        #expect(saved.additionalRDPSettings == ["audiocapturemode:i:1"])
    }

    @Test
    func turningOffNLASaysWhatItCosts() {
        var weaker = draft()
        #expect(weaker.nlaWarning == nil)
        weaker.requiresNLA = false
        #expect(weaker.nlaWarning?.isEmpty == false)
        #expect(weaker.connection()?.requiresNLA == false)
    }
}

@Suite(.serialized)
@MainActor
struct ConnectionManagementTests {
    private func names(_ model: LibraryModel) -> [String] {
        model.library.connections.map(\.name)
    }

    /// Waits for work an undo or redo started in a task.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test
    func savingReplacesTheConnectionWithTheSameIdentifier() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        var jump = try #require(model.library.connections.first { $0.name == "Jump Host" })
        jump.host = "jump2.example.com"
        await model.save(jump)
        #expect(model.library.connections.count == 4)
        #expect(model.connection(jump.id)?.host == "jump2.example.com")
    }

    @Test
    func aDuplicateFollowsItsOriginalUnderANewNameAndIdentity() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let build = try #require(model.library.connections.first { $0.name == "Build Server" })
        let first = await model.duplicate([build.id])
        let second = await model.duplicate([build.id])
        #expect(names(model).prefix(3) == ["Build Server", "Build Server Copy 2", "Build Server Copy"])
        let copy = try #require(first.first.flatMap(model.connection))
        #expect(copy.id != build.id)
        #expect(copy.host == build.host)
        #expect(copy.lastConnectedAt == nil)
        #expect(!copy.isFavorite)
        #expect(second.count == 1)
    }

    @Test
    func deletingAsksNothingAndUndoAndRedoWork() async throws {
        let (model, directory) = try await temporaryLibrary(SampleLibrary.library)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let ids = Set(model.library.connections.filter { $0.name.hasPrefix("Build") || $0.name.hasPrefix("Jump") }
            .map(\.id))

        undo.beginUndoGrouping()
        await model.delete(ids, undoManager: undo)
        undo.endUndoGrouping()
        #expect(names(model) == ["Finance VM", "Lab Desktop"])
        #expect(undo.undoActionName == "Delete Connections")

        undo.undo()
        await settle()
        #expect(names(model) == ["Build Server", "Finance VM", "Jump Host", "Lab Desktop"])
        #expect(model.selectedIDs == ids)
        let reopened = LibraryModel(store: ConnectionStore(directory: directory))
        await reopened.load()
        #expect(reopened.library.connections.count == 4)

        undo.redo()
        await settle()
        #expect(names(model) == ["Finance VM", "Lab Desktop"])
    }

    @Test
    func keychainItemsOfDeletedConnectionsGoOnlyWhenNothingCanBringThemBack() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let store = InMemoryCredentialStore()
        let kept = try #require(model.library.connections.first)
        let gone = Connection(name: "Old", host: "old")
        for key in [kept.id.uuidString, gone.id.uuidString, "typed.example.com:3389"] {
            try store.save(StoredCredentials(username: "u", password: "p"), for: key, label: "Test")
        }
        model.removeOrphanedCredentials(from: store)
        try #expect(store.keys() == [kept.id.uuidString])
    }

    @Test
    func anUnreadableLibraryNeverCostsAPassword() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: directory.appendingPathComponent(ConnectionStore.fileName))
        let model = LibraryModel(store: ConnectionStore(directory: directory))
        await model.load()

        let store = InMemoryCredentialStore()
        try store.save(StoredCredentials(username: "u", password: "p"), for: UUID().uuidString, label: "Test")
        model.removeOrphanedCredentials(from: store)
        try #expect(store.keys().count == 1)
    }
}
