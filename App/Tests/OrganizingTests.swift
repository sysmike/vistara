import Foundation
import Testing
import UniformTypeIdentifiers
import VistaraCore
@testable import Vistara

@Suite(.serialized)
@MainActor
struct OrganizingTests {
    private func names(_ model: LibraryModel) -> [String] {
        model.visibleConnections.map(\.name)
    }

    private func id(_ name: String, in model: LibraryModel) throws -> Connection.ID {
        try #require(model.library.connections.first { $0.name == name }).id
    }

    // MARK: Folders

    @Test
    func aNewFolderIsNamedSelectedAndReadyToRename() async throws {
        let (model, _) = try await temporaryLibrary()
        let first = try #require(model.addFolder())
        let second = try #require(model.addFolder())
        #expect(model.library.folders.map(\.name) == ["New Folder", "New Folder 2"])
        #expect(model.selection == .folder(second))
        #expect(model.renamingFolderID == second)

        model.renameFolder(first, to: "  Office ")
        model.renameFolder(second, to: "   ")
        #expect(model.library.folders.map(\.name) == ["Office", "New Folder 2"])
        #expect(model.renamingFolderID == nil)
    }

    @Test
    func deletingAFolderKeepsItsConnectionsAndUndoPutsThemBack() async throws {
        let (model, directory) = try await temporaryLibrary(SampleLibrary.library)
        let lab = SampleLibrary.lab.id
        model.selection = .folder(lab)
        #expect(model.count(in: lab) == 2)
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        model.deleteFolder(lab, undoManager: undo)
        undo.endUndoGrouping()
        #expect(model.folders.map(\.name) == ["Office"])
        #expect(model.library.connections.count == 4)
        #expect(model.library.connections.allSatisfy { $0.folderID != lab })
        #expect(model.selection == .all)
        #expect(undo.undoActionName == "Delete Folder")

        undo.undo()
        #expect(model.folders.map(\.name) == ["Lab", "Office"])
        #expect(model.count(in: lab) == 2)
        #expect(model.selection == .folder(lab))
        #expect(undo.canRedo)
        await model.flushSaves()
        let reopened = LibraryModel(store: ConnectionStore(directory: directory))
        await reopened.load()
        #expect(reopened.count(in: lab) == 2)

        undo.redo()
        #expect(model.folders.map(\.name) == ["Office"])
    }

    @Test
    func movingIntoAFolderIsUndoable() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let office = SampleLibrary.office.id
        let ids: Set = [try id("Jump Host", in: model), try id("Build Server", in: model)]
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        model.move(ids, to: office, undoManager: undo)
        undo.endUndoGrouping()
        #expect(model.count(in: office) == 3)
        #expect(ConnectionsView.commonFolder(of: ids, in: model.library) == .some(office))

        undo.undo()
        #expect(model.count(in: office) == 1)
        #expect(model.connection(try id("Build Server", in: model))?.folderID == SampleLibrary.lab.id)
        #expect(model.connection(try id("Jump Host", in: model))?.folderID == nil)
        // Different folders: none shared.
        #expect(ConnectionsView.commonFolder(of: ids, in: model.library) == nil)

        // Out of any folder.
        model.move(ids, to: nil, undoManager: nil)
        #expect(ConnectionsView.commonFolder(of: ids, in: model.library) == .some(nil))
    }

    @Test
    func aMoveToAFolderThatIsGoneDoesNothing() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let jump = try id("Jump Host", in: model)
        model.move([jump], to: UUID(), undoManager: nil)
        #expect(model.connection(jump)?.folderID == nil)
    }

    // MARK: Favorites and tags

    @Test
    func favoritesToggleAllOrNone() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let build = try id("Build Server", in: model)
        let jump = try id("Jump Host", in: model)
        #expect(model.wouldFavorite([build, jump]))
        model.toggleFavorite([build, jump])
        #expect(model.connection(jump)?.isFavorite == true)
        #expect(!model.wouldFavorite([build, jump]))
        model.toggleFavorite([build, jump])
        model.selection = .favorites
        #expect(names(model).isEmpty)
    }

    @Test
    func aNewTagTakesTheSpellingAlreadyInUse() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let jump = try id("Jump Host", in: model)
        model.addTag(" PROD ", to: [jump])
        model.addTag("prod", to: [jump])
        #expect(model.connection(jump)?.tags == ["test", "prod"])
        #expect(model.tags == ["finance", "prod", "test"])
    }

    @Test
    func editorTagsAreTrimmedAndNeverRepeated() {
        #expect(ConnectionDraft.normalizedTags([" prod", "", "Prod", "ci ", "  "]) == ["prod", "ci"])
        var draft = ConnectionDraft()
        draft.host = "build01"
        draft.tags = ["a", "A", " b "]
        #expect(draft.connection()?.tags == ["a", "b"])
    }

    // MARK: Recents

    @Test
    func recentsAreTheLastUsedNewestFirst() async throws {
        var library = Library()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for number in 0..<25 {
            var connection = Connection(name: "Server \(number)", host: "h\(number)")
            connection.lastConnectedAt = start.addingTimeInterval(Double(number) * 60)
            library.connections.append(connection)
        }
        library.connections.append(Connection(name: "Never Used", host: "n"))
        let (model, _) = try await temporaryLibrary(library)

        model.selection = .recents
        #expect(names(model).count == LibraryModel.recentsLimit)
        #expect(names(model).first == "Server 24")
        #expect(names(model).last == "Server 5")
        #expect(!names(model).contains("Never Used"))

        // Sorting by name is still possible within Recents.
        model.sortOrder = [KeyPathComparator(\Connection.name, comparator: .localizedStandard)]
        #expect(names(model).first == "Server 5")
    }

    // MARK: Dragging

    @Test
    func aDraggedConnectionIsOfAKindTheAppDeclares() throws {
        #expect(UTType.vistaraConnection.isDeclared)
        #expect(UTType.vistaraConnection.conforms(to: .data))

        var connection = Connection(name: "Jump", host: "jump.example.com")
        connection.port = 3390
        let reference = ConnectionReference(connection)
        #expect(reference.address == "jump.example.com:3390")
        let decoded = try JSONDecoder().decode(ConnectionReference.self, from: JSONEncoder().encode(reference))
        #expect(decoded.id == connection.id)
    }
}
