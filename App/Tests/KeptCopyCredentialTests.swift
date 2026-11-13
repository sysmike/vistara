import Foundation
import Testing
import VistaraCore
@testable import Vistara

/// A password stays as long as a copy of the library file still holds its
/// connection (#84).
@Suite(.serialized)
@MainActor
struct KeptCopyCredentialTests {
    private func makeDirectory(with contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appendingPathComponent(ConnectionStore.fileName))
        return directory
    }

    private func loadedModel(in directory: URL) async -> LibraryModel {
        let model = LibraryModel(store: ConnectionStore(directory: directory))
        await model.load()
        return model
    }

    private func store(with keys: [String]) throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        for key in keys {
            try store.save(StoredCredentials(username: "u", password: "p"), for: key, label: "Test")
        }
        return store
    }

    @Test
    func anUnreadableConnectionKeepsItsPasswordAfterTheFileIsSavedWithoutIt() async throws {
        let good = UUID()
        let bad = UUID()
        let orphan = UUID().uuidString
        let directory = try makeDirectory(with: """
            {"schemaVersion": 1, "connections": [
                {"id": "\(good.uuidString)", "name": "Build Server", "host": "build01"},
                {"id": "\(bad.uuidString)", "name": "Broken"}
            ]}
            """)
        let first = await loadedModel(in: directory)
        let copy = try #require(first.originalFileCopy)
        // Any change saves the file, now without the unreadable connection.
        await first.recordConnection(good)
        let credentials = try store(with: [good.uuidString, bad.uuidString, orphan])

        // The next launch no longer finds the connection in the file.
        let second = await loadedModel(in: directory)
        #expect(second.skippedEntries.isEmpty)
        second.removeOrphanedCredentials(from: credentials)
        try #expect(Set(credentials.keys()) == [good.uuidString, bad.uuidString])

        // Once the copy is gone, so is the connection, and its password goes.
        try FileManager.default.removeItem(at: copy)
        let third = await loadedModel(in: directory)
        third.removeOrphanedCredentials(from: credentials)
        try #expect(credentials.keys() == [good.uuidString])
    }

    @Test
    func aFileThatCannotBeReadAtAllCostsNoPassword() async throws {
        let saved = UUID()
        let orphan = UUID().uuidString
        let directory = try makeDirectory(with: #"{"schemaVersion": 1, "connections": [{"id": "\#(saved)", "na"#)
        let model = await loadedModel(in: directory)
        #expect(model.corruptFileBackup != nil)
        #expect(model.library.connections.isEmpty)

        let credentials = try store(with: [saved.uuidString, orphan])
        model.removeOrphanedCredentials(from: credentials)
        try #expect(credentials.keys() == [saved.uuidString])
    }
}
