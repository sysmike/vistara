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

@Test func structurallyWrongFileIsMovedAside() async throws {
    let temporary = TemporaryStore()
    defer { temporary.cleanUp() }
    try temporary.write(#"{"schemaVersion": 1, "connections": [{"name": "no id or host"}]}"#)

    let result = try await temporary.store.load()
    #expect(result.corruptFileBackup != nil)
    #expect(result.library == Library())
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
