import Foundation
import Testing

@testable import VistaraCore

/// A store in its own temporary directory, removed when the test ends.
private struct TemporaryStore {
    let directory: URL
    let store: ConnectionStore
    var fileURL: URL { directory.appendingPathComponent(ConnectionStore.fileName) }

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VistaraTests-\(UUID().uuidString)", isDirectory: true)
        store = ConnectionStore(directory: directory)
    }

    func write(_ contents: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func loadingWithoutAFileGivesAnEmptyLibrary() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }

    let result = try await temporary.store.load()
    #expect(result.library == Library())
    #expect(result.corruptFileBackup == nil)
}

@Test func savedLibraryLoadsBack() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    let library = Library(
        connections: [Connection(name: "Build Server", host: "build01.example.com")],
        folders: [Folder(name: "Office")]
    )

    try await temporary.store.save(library)
    let result = try await temporary.store.load()
    #expect(result.library == library)
    #expect(result.corruptFileBackup == nil)
}

@Test func savedFileIsPrivateToTheUser() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }

    try await temporary.store.save(Library())
    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.fileURL.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test func corruptFileIsMovedAsideAndReported() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    try temporary.write("{ this is not JSON")

    let result = try await temporary.store.load()
    let backup = try #require(result.corruptFileBackup)
    #expect(result.library == Library())
    #expect(try String(contentsOf: backup, encoding: .utf8) == "{ this is not JSON")
    #expect(!FileManager.default.fileExists(atPath: temporary.fileURL.path))
}

@Test func aFileWithAWrongListIsMovedAside() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    try temporary.write(#"{"schemaVersion": 1, "connections": "everything"}"#)

    let result = try await temporary.store.load()
    #expect(result.corruptFileBackup != nil)
    #expect(result.library == Library())
}

@Test func unreadableEntriesAreLeftOutAndTheFileIsCopiedBeforeTheNextSave() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    let contents = """
        {"schemaVersion": 1, "connections": [
            {"id": "6C1F6E2A-6B1D-4A63-9C3B-1F0C2D3E4F50", "name": "Build Server", "host": "build01"},
            {"name": "no id or host"}
        ]}
        """
    try temporary.write(contents)

    let result = try await temporary.store.load()
    #expect(result.corruptFileBackup == nil)
    #expect(result.library.connections.map(\.name) == ["Build Server"])
    #expect(result.skippedEntries == [.init(kind: .connection, id: nil)])
    let copy = try #require(result.originalFileCopy)
    #expect(copy.lastPathComponent.hasPrefix("connections.unreadable-"))
    #expect(try String(contentsOf: copy, encoding: .utf8) == contents)

    // Saving leaves the bad entry out of the file; the copy keeps it.
    try await temporary.store.save(result.library)
    let reloaded = try await temporary.store.load()
    #expect(reloaded.skippedEntries.isEmpty)
    #expect(reloaded.originalFileCopy == nil)
    #expect(try String(contentsOf: copy, encoding: .utf8) == contents)
}

@Test func fileFromANewerVersionIsLeftUntouched() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    let contents = #"{"schemaVersion": 99, "connections": []}"#
    try temporary.write(contents)

    await #expect(throws: LibraryCodec.CodecError.newerSchema(found: 99, supported: 1)) {
        try await temporary.store.load()
    }
    #expect(try String(contentsOf: temporary.fileURL, encoding: .utf8) == contents)
}

@Test func concurrentSavesLeaveOneValidFile() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    let store = temporary.store

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<50 {
            group.addTask {
                try await store.save(Library(connections: [Connection(name: "Connection \(index)", host: "host")]))
            }
        }
        try await group.waitForAll()
    }

    let result = try await store.load()
    #expect(result.corruptFileBackup == nil)
    #expect(result.library.connections.count == 1)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.directory.path)
    #expect(leftovers == [ConnectionStore.fileName])
}

@Test func theKeptCopiesNameTheirConnections() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    let unreadable = "6C1F6E2A-6B1D-4A63-9C3B-1F0C2D3E4F50"
    let corrupt = "0b9e8d7c-6b5a-4f3e-8d2c-1b0a99887766"
    let current = "11111111-2222-3333-4444-555555555555"
    try temporary.write("""
        {"schemaVersion": 1, "connections": [
            {"id": "\(current)", "name": "Build Server", "host": "build01"},
            {"id": "\(unreadable)", "name": "No Host"}
        ]}
        """)
    let result = try await temporary.store.load()
    #expect(result.originalFileCopy != nil)
    try await temporary.store.save(result.library)

    // A copy that is no longer JSON at all still counts, and so does one in
    // lower case. Other files in the folder do not.
    let directory = temporary.directory
    try Data(#"{"schemaVersion": 1, "connections": [{"id": "\#(corrupt)", "#.utf8)
        .write(to: directory.appendingPathComponent("connections.corrupt-20261113-090000.json"))
    try Data(#"{"id": "22222222-3333-4444-5555-666666666666"}"#.utf8)
        .write(to: directory.appendingPathComponent("connections.unreadable-notes.txt"))

    let identifiers = await temporary.store.identifiersInKeptCopies()
    // The copy also holds the readable connection, which is still in the file.
    #expect(identifiers == [unreadable, corrupt.uppercased(), current])
}

@Test func withoutKeptCopiesThereAreNoIdentifiers() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    #expect(await temporary.store.identifiersInKeptCopies().isEmpty)
    try temporary.write(#"{"schemaVersion": 1, "connections": [{"id": "\#(UUID().uuidString)", "host": "h"}]}"#)
    #expect(await temporary.store.identifiersInKeptCopies().isEmpty)
}
