import Foundation
import Testing
import VistaraCore
@testable import Vistara

/// Macs, each with its own library, and a folder they may share, as in iCloud Drive.
@MainActor
private struct SharedFolder {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vistara-sync-\(UUID().uuidString)", isDirectory: true)
    var folder: URL { root.appendingPathComponent("iCloud Drive", isDirectory: true) }
    var connectionFiles: URL {
        folder.appendingPathComponent("Vistara Connections/connections", isDirectory: true)
    }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// One Mac's library, loaded, keeping these connections on this Mac.
    func mac(_ name: String, with connections: [Connection] = []) async throws -> LibraryModel {
        let store = ConnectionStore(directory: root.appendingPathComponent(name, isDirectory: true))
        if !connections.isEmpty { try await store.save(Library(connections: connections)) }
        let model = LibraryModel(store: store)
        await model.load()
        return model
    }

    /// One Mac's library, kept in the folder.
    func joined(_ name: String, with connections: [Connection] = []) async throws -> LibraryModel {
        let model = try await mac(name, with: connections)
        try await model.keepInFolder(folder)
        return model
    }

    func filesInFolder() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: connectionFiles.path)) ?? []).sorted()
    }

    func cleanUp(_ models: LibraryModel...) async {
        for model in models { await model.keepOnThisMac() }
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized)
@MainActor
struct SyncTests {
    private func names(_ model: LibraryModel) -> [String] { model.library.connections.map(\.name).sorted() }

    @Test
    func twoLibrariesOnOneFolderSeeEachOthersChanges() async throws {
        let shared = try SharedFolder()
        let first = try await shared.joined("First Mac")
        let second = try await shared.joined("Second Mac")

        let build = Connection(name: "Build Server", host: "build01")
        await first.add(build)
        await second.syncNow()
        #expect(names(second) == ["Build Server"])
        #expect(second.syncState == .reachable)

        var renamed = try #require(second.connection(build.id))
        renamed.name = "Build Server 2"
        await second.save(renamed)
        await first.syncNow()
        #expect(names(first) == ["Build Server 2"])

        first.delete([build.id], undoManager: nil)
        await first.flushSaves()
        await second.syncNow()
        #expect(second.library.connections.isEmpty)
        await shared.cleanUp(first, second)
    }

    @Test
    func anotherMacsChangeShowsWithinSecondsWithoutAsking() async throws {
        let shared = try SharedFolder()
        let first = try await shared.joined("First Mac")
        let second = try await shared.joined("Second Mac")

        await first.add(Connection(name: "Build Server", host: "build01"))
        await waitUntil("the second Mac shows the first Mac's new connection", within: .seconds(10)) {
            names(second) == ["Build Server"]
        }
        await shared.cleanUp(first, second)
    }

    @Test
    func choosingAFolderAddsThisMacsConnectionsAndDeletesNothing() async throws {
        let shared = try SharedFolder()
        let first = try await shared.joined("First Mac", with: [Connection(name: "Build", host: "build01")])
        let second = try await shared.joined("Second Mac", with: [Connection(name: "Jump", host: "jump01")])
        #expect(names(second) == ["Build", "Jump"])
        await first.syncNow()
        #expect(names(first) == ["Build", "Jump"])
        #expect(shared.filesInFolder().count == 2)
        await shared.cleanUp(first, second)
    }

    @Test
    func goingBackToOnThisMacKeepsTheConnectionsAndLeavesTheFolderAlone() async throws {
        let shared = try SharedFolder()
        let first = try await shared.joined("First Mac", with: [Connection(name: "Build", host: "build01")])
        let second = try await shared.joined("Second Mac", with: [Connection(name: "Jump", host: "jump01")])
        await first.syncNow()

        await first.keepOnThisMac()
        #expect(first.syncFolder == nil)
        #expect(first.syncState == nil)
        #expect(names(first) == ["Build", "Jump"])
        await first.add(Connection(name: "Lab", host: "lab01"))
        #expect(shared.filesInFolder().count == 2)

        // After a relaunch too, on this Mac only.
        let relaunched = try await shared.mac("First Mac")
        #expect(names(relaunched) == ["Build", "Jump", "Lab"])
        await second.syncNow()
        #expect(names(second) == ["Build", "Jump"])
        await shared.cleanUp(first, second)
    }

    @Test
    func aConnectionDeletedOnAnotherMacTakesItsPasswordHere() async throws {
        let shared = try SharedFolder()
        let build = Connection(name: "Build", host: "build01")
        let jump = Connection(name: "Jump", host: "jump01")
        let first = try await shared.joined("First Mac", with: [build, jump])
        let second = try await shared.joined("Second Mac")
        let passwords = InMemoryCredentialStore()
        let credentials = StoredCredentials(username: "u", password: "p")
        for connection in [build, jump] {
            try passwords.save(credentials, for: connection.id.uuidString, label: "Test")
        }

        first.delete([build.id], undoManager: nil)
        await first.flushSaves()
        await second.syncNow()
        second.removeOrphanedCredentials(from: passwords)

        try #expect(passwords.keys() == [jump.id.uuidString])
        await shared.cleanUp(first, second)
    }

    @Test
    func changesWaitWhileTheFolderIsAwayAndAreWrittenWhenItIsBack() async throws {
        let shared = try SharedFolder()
        let first = try await shared.joined("First Mac")
        try FileManager.default.removeItem(at: shared.folder)

        await first.add(Connection(name: "Build", host: "build01"))
        #expect(first.syncState == .unreachable)
        #expect(names(first) == ["Build"])
        #expect(!first.saveFailed)

        try FileManager.default.createDirectory(at: shared.folder, withIntermediateDirectories: true)
        await waitUntil("the folder is back", within: .seconds(10)) { first.syncState == .reachable }
        #expect(shared.filesInFolder().count == 1)
        await shared.cleanUp(first)
    }

    @Test
    func aFolderThatMovedIsFollowed() async throws {
        let shared = try SharedFolder()
        let first = try await shared.joined("First Mac", with: [Connection(name: "Build", host: "build01")])
        let moved = shared.root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: shared.folder, to: moved)

        await waitUntil("the moved folder is used", within: .seconds(10)) {
            first.syncFolder.map { SharedFolderAccess.isSamePlace(moved, $0.path) } == true
                && first.syncState == .reachable
        }
        await first.add(Connection(name: "Jump", host: "jump01"))
        let files = try FileManager.default.contentsOfDirectory(
            atPath: moved.appendingPathComponent("Vistara Connections/connections").path
        )
        #expect(files.count == 2)
        await shared.cleanUp(first)
    }
}
