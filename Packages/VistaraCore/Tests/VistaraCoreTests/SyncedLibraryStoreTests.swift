import Foundation
import os
import Testing

@testable import VistaraCore

/// A clock the test moves, in whole seconds as the files keep them.
final class TestClock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval = 1) { time.withLock { $0 += seconds } }
}

/// Two Macs, each with its own library directory, sharing one sync folder.
private struct TwoMacs {
    let root: URL
    let shared: URL
    let clock: TestClock
    let first: SyncedLibraryStore
    let second: SyncedLibraryStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VistaraSync-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("iCloud Drive", isDirectory: true)
        let clock = TestClock()
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        self.root = root
        self.shared = shared
        self.clock = clock
        first = Self.store("First Mac", root: root, shared: shared, clock: clock)
        second = Self.store("Second Mac", root: root, shared: shared, clock: clock)
    }

    /// A store for one Mac, as a relaunch of it would make.
    func store(_ mac: String) -> SyncedLibraryStore {
        Self.store(mac, root: root, shared: shared, clock: clock)
    }

    private static func store(_ mac: String, root: URL, shared: URL, clock: TestClock) -> SyncedLibraryStore {
        SyncedLibraryStore(
            localDirectory: root.appendingPathComponent(mac, isDirectory: true), folder: shared, now: { clock.now() }
        )
    }

    var entries: URL { shared.appendingPathComponent("Vistara Connections", isDirectory: true) }

    func file(_ kind: String, _ id: UUID) -> URL {
        entries.appendingPathComponent(kind).appendingPathComponent("\(id.uuidString).json")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite
struct SyncedLibraryStoreTests {
    private func names(_ library: Library) -> [String] { library.connections.map(\.name).sorted() }

    @Test func entriesAddedChangedAndDeletedOnOneMacShowOnTheOther() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        _ = try await macs.first.load()
        _ = try await macs.second.load()
        var connection = Connection(name: "Build Server", host: "build01")
        let folder = Folder(name: "Office")
        connection.folderID = folder.id

        var mine = try await macs.first.save(Library(connections: [connection], folders: [folder])).library
        var theirs = try await macs.second.sync()
        #expect(theirs.folder == .reachable)
        #expect(names(theirs.library) == ["Build Server"])
        #expect(theirs.library.folders.map(\.name) == ["Office"])
        #expect(theirs.library.connections.first?.folderID == folder.id)

        macs.clock.advance()
        mine.connections[0].name = "Build Server 2"
        mine = try await macs.first.save(mine).library
        theirs = try await macs.second.sync()
        #expect(names(theirs.library) == ["Build Server 2"])

        macs.clock.advance()
        mine.connections = []
        _ = try await macs.first.save(mine)
        theirs = try await macs.second.sync()
        #expect(theirs.library.connections.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: macs.file("connections", connection.id).path))
        #expect(FileManager.default.fileExists(atPath: macs.file("deleted", connection.id).path))
    }

    @Test func theLaterChangeOfTheSameConnectionWins() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let connection = Connection(name: "Build Server", host: "build01")
        var mine = try await macs.first.save(Library(connections: [connection])).library
        var theirs = try await macs.second.sync().library

        // Both change it before hearing of the other's change; the second Mac's is later.
        macs.clock.advance()
        mine.connections[0].port = 3390
        mine = try await macs.first.save(mine).library
        macs.clock.advance()
        theirs.connections[0].username = "alice"
        theirs = try await macs.second.save(theirs).library
        mine = try await macs.first.sync().library

        #expect(theirs.connections.first?.username == "alice")
        #expect(theirs.connections.first?.port == 3389)
        #expect(mine == theirs)
    }

    @Test func aConflictCopyIsMergedAndRemoved() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let connection = Connection(name: "Build Server", host: "build01")
        _ = try await macs.first.save(Library(connections: [connection]))
        // A sync service's copy, newer than the file it sits next to.
        var newer = connection
        newer.name = "Build Server (renamed)"
        newer.modifiedAt = macs.clock.now().addingTimeInterval(60)
        let copy = macs.entries.appendingPathComponent("connections/\(connection.id.uuidString) 2.json")
        try LibraryCodec.entryData(newer).write(to: copy)

        let result = try await macs.second.sync()

        #expect(names(result.library) == ["Build Server (renamed)"])
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        let own = try Data(contentsOf: macs.file("connections", connection.id))
        #expect(LibraryCodec.entry(Connection.self, from: own)?.name == "Build Server (renamed)")
    }

    @Test func deletionMarkersGoAfterNinetyDays() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let connection = Connection(name: "Build Server", host: "build01")
        let library = try await macs.first.save(Library(connections: [connection])).library
        macs.clock.advance()
        _ = try await macs.first.save(Library(connections: library.connections.filter { $0.id != connection.id }))
        #expect(FileManager.default.fileExists(atPath: macs.file("deleted", connection.id).path))

        macs.clock.advance(91 * 24 * 60 * 60)
        _ = try await macs.second.sync()

        #expect(!FileManager.default.fileExists(atPath: macs.file("deleted", connection.id).path))
    }

    @Test func sharedFoldersAndLastUseStayOnEachMac() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        var connection = Connection(name: "Build Server", host: "build01")
        connection.sharedFolders = [.init(path: "/Users/alice/Transfer", bookmark: Data([1, 2, 3]), isReadOnly: true)]
        connection.lastConnectedAt = macs.clock.now()
        _ = try await macs.first.save(Library(connections: [connection]))

        var theirs = try await macs.second.sync().library
        #expect(theirs.connections.first?.sharedFolders.isEmpty == true)
        #expect(theirs.connections.first?.lastConnectedAt == nil)
        let file = try Data(contentsOf: macs.file("connections", connection.id))
        #expect(!String(decoding: file, as: UTF8.self).contains("Transfer"))

        // Using it on the second Mac changes nothing shared.
        macs.clock.advance()
        theirs.connections[0].lastConnectedAt = macs.clock.now()
        theirs = try await macs.second.save(theirs).library
        #expect(try Data(contentsOf: macs.file("connections", connection.id)) == file)
        let mine = try await macs.first.sync().library
        #expect(mine.connections.first?.sharedFolders.count == 1)
        #expect(mine.connections.first?.lastConnectedAt == connection.lastConnectedAt)
        #expect(theirs.connections.first?.lastConnectedAt == macs.clock.now())
    }

    @Test func changesMadeWhileTheFolderIsGoneAreWrittenWhenItIsBack() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let kept = Connection(name: "Build Server", host: "build01")
        let gone = Connection(name: "Old Server", host: "old01")
        var library = try await macs.first.save(Library(connections: [kept, gone])).library
        _ = try await macs.second.sync()

        let away = macs.root.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: macs.shared, to: away)
        macs.clock.advance()
        library.connections.removeAll { $0.id == gone.id }
        library.connections.append(Connection(name: "New Server", host: "new01"))
        let offline = try await macs.first.save(library)
        #expect(offline.folder == .unreachable)
        #expect(names(offline.library) == ["Build Server", "New Server"])

        // A relaunch meanwhile forgets nothing.
        let relaunched = macs.store("First Mac")
        #expect(try await names(relaunched.load().library) == ["Build Server", "New Server"])
        try FileManager.default.moveItem(at: away, to: macs.shared)
        #expect(try await relaunched.sync().folder == .reachable)

        let theirs = try await macs.second.sync()
        #expect(names(theirs.library) == ["Build Server", "New Server"])
    }

    @Test func joiningAddsBothMacsConnectionsAndDeletesNothing() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        // Each Mac's own library, from before a folder was chosen.
        let localOnly = { (mac: String, name: String) in
            try await ConnectionStore(directory: macs.root.appendingPathComponent(mac, isDirectory: true))
                .save(Library(connections: [Connection(name: name, host: name.lowercased())]))
        }
        try await localOnly("First Mac", "Build")
        try await localOnly("Second Mac", "Jump")
        _ = try await macs.first.load()
        _ = try await macs.second.load()

        _ = try await macs.first.sync()
        let theirs = try await macs.second.sync()
        let mine = try await macs.first.sync()

        #expect(names(theirs.library) == ["Build", "Jump"])
        #expect(names(mine.library) == ["Build", "Jump"])
    }

    @Test func aFolderWrittenByANewerVistaraIsLeftAlone() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        try FileManager.default.createDirectory(at: macs.entries, withIntermediateDirectories: true)
        let layout = Data(#"{"layout":2,"schemaVersion":1}"#.utf8)
        try layout.write(to: macs.entries.appendingPathComponent("layout.json"))

        let result = try await macs.first.save(Library(connections: [Connection(name: "Build", host: "build")]))

        #expect(result.folder == .newerLayout)
        #expect(names(result.library) == ["Build"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: macs.entries.path) == ["layout.json"])
        #expect(try Data(contentsOf: macs.entries.appendingPathComponent("layout.json")) == layout)
    }

    @Test func aDamagedEntryIsSkippedAndKept() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        _ = try await macs.first.save(Library(connections: [Connection(name: "Build", host: "build")]))
        let damaged = macs.entries.appendingPathComponent("connections/\(UUID().uuidString).json")
        try Data("not JSON".utf8).write(to: damaged)

        let result = try await macs.second.sync()

        #expect(names(result.library) == ["Build"])
        #expect(result.damagedFiles == [damaged.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: damaged.path))
    }
}

/// The merge on its own.
@Suite
struct LibraryMergeTests {
    private let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { earlier.addingTimeInterval(10) }

    private func connection(_ name: String, id: UUID, at date: Date?) -> Connection {
        var connection = Connection(id: id, name: name, host: "host")
        connection.modifiedAt = date
        return connection
    }

    @Test func aTieGoesToTheFolder() {
        let id = UUID()
        let outcome = LibraryMerge.merge(
            local: Library(connections: [connection("Here", id: id, at: earlier)]), localDeletions: [:],
            folder: SyncFolderContents(connections: [id: connection("There", id: id, at: earlier)])
        )
        #expect(outcome.library.connections.map(\.name) == ["There"])
        #expect(outcome.connectionsToWrite.isEmpty)
    }

    @Test func aChangeAfterADeletionKeepsTheEntry() {
        let id = UUID()
        let kept = LibraryMerge.merge(
            local: Library(connections: [connection("Here", id: id, at: later)]), localDeletions: [:],
            folder: SyncFolderContents(deletions: [id: earlier])
        )
        #expect(kept.library.connections.map(\.name) == ["Here"])
        #expect(kept.connectionsToWrite.map(\.name) == ["Here"])

        let deleted = LibraryMerge.merge(
            local: Library(connections: [connection("Here", id: id, at: earlier)]), localDeletions: [:],
            folder: SyncFolderContents(
                connections: [id: connection("There", id: id, at: earlier)], deletions: [id: later]
            )
        )
        #expect(deleted.library.connections.isEmpty)
        #expect(deleted.filesToRemove == [id])
    }

    @Test func thisMacsDeletionsGoToTheFolder() {
        let id = UUID()
        let outcome = LibraryMerge.merge(
            local: Library(), localDeletions: [id: later],
            folder: SyncFolderContents(connections: [id: connection("There", id: id, at: earlier)])
        )
        #expect(outcome.library.connections.isEmpty)
        #expect(outcome.deletionsToWrite == [id: later])
        #expect(outcome.filesToRemove == [id])
    }
}
