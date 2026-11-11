import Foundation
import Testing

@testable import VistaraCore

private func fullyPopulatedLibrary() -> Library {
    let folder = Folder(name: "Office")
    var connection = Connection(name: "Build Server", host: "build01.example.com")
    connection.port = 3390
    connection.username = "alice"
    connection.domain = "EXAMPLE"
    connection.folderID = folder.id
    connection.tags = ["prod", "ci"]
    connection.isFavorite = true
    connection.lastConnectedAt = Date(timeIntervalSince1970: 1_700_000_000)
    connection.resolutionMode = .fixed
    connection.fixedWidth = 2560
    connection.fixedHeight = 1440
    connection.usesHiDPI = false
    connection.sharesClipboard = false
    connection.audioMode = .off
    connection.sharedFolders = [.init(path: "/Users/alice/Transfer", bookmark: Data([1, 2, 3]), isReadOnly: true)]
    connection.reconnectsAutomatically = false
    connection.requiresNLA = false
    connection.certificatePolicy = .requireTrusted
    return Library(connections: [connection, Connection(name: "Jump Host", host: "10.0.4.17")], folders: [folder])
}

private func keys(in value: JSONValue) -> [String] {
    switch value {
    case .object(let fields): Array(fields.keys) + fields.values.flatMap(keys(in:))
    case .array(let items): items.flatMap(keys(in:))
    default: []
    }
}

@Test func libraryRoundTrips() throws {
    let library = fullyPopulatedLibrary()
    #expect(try LibraryCodec.decode(LibraryCodec.encode(library)) == library)
}

@Test func encodedFileStatesItsSchemaVersion() throws {
    let root = try JSONDecoder().decode(JSONValue.self, from: LibraryCodec.encode(Library()))
    #expect(root == .object(["schemaVersion": .integer(1), "connections": .array([]), "folders": .array([])]))
}

@Test func missingOptionalFieldsTakeDefaults() throws {
    let json = """
        {"schemaVersion": 1, "connections": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Minimal", "host": "example.com"}
        ]}
        """
    let library = try LibraryCodec.decode(Data(json.utf8))
    let expected = Connection(
        id: try #require(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")),
        name: "Minimal",
        host: "example.com"
    )
    #expect(library.connections == [expected])
    #expect(library.folders.isEmpty)
}

@Test func unknownFieldsSurviveLoadAndSave() throws {
    let json = """
        {"schemaVersion": 1, "futureSetting": {"enabled": true},
         "connections": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "A", "host": "a", "gateway": "gw"}],
         "folders": [{"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "F", "color": 3}]}
        """
    var library = try LibraryCodec.decode(Data(json.utf8))
    library.connections[0].name = "Renamed"

    let saved = try LibraryCodec.decode(LibraryCodec.encode(library))
    #expect(saved.unknownFields == ["futureSetting": .object(["enabled": .bool(true)])])
    #expect(saved.connections[0].unknownFields == ["gateway": .string("gw")])
    #expect(saved.connections[0].name == "Renamed")
    #expect(saved.folders[0].unknownFields == ["color": .integer(3)])
}

@Test func noSecretIsEverEncoded() throws {
    // Even a secret smuggled in as an unknown field must not be written back.
    let json = """
        {"schemaVersion": 1, "apiToken": "t",
         "connections": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "A", "host": "a",
                          "password": "hunter2", "clearTextPassword": "hunter2"}]}
        """
    var library = try LibraryCodec.decode(Data(json.utf8))
    library.connections += fullyPopulatedLibrary().connections
    library.connections[1].unknownFields["Password"] = .string("hunter2")

    let data = try LibraryCodec.encode(library)
    let encodedKeys = keys(in: try JSONDecoder().decode(JSONValue.self, from: data))
    #expect(encodedKeys.filter(LibraryCodec.isSecretLike).isEmpty)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("hunter2"))
}

@Test func olderFilesAreMigratedStepByStep() throws {
    // Version 1 is the only real schema so far, so this drives the mechanism
    // with two made-up steps: 1 -> 2 renames a key, 2 -> 3 adds a folder.
    let migrations: [Int: LibraryCodec.Migration] = [
        1: { root in
            root["connections"] = root.removeValue(forKey: "servers")
        },
        2: { root in
            root["folders"] = .array([
                .object(["id": .string("7F9619FF-8B86-D011-B42D-00C04FC964FF"), "name": .string("Imported")])
            ])
        }
    ]
    let json = """
        {"schemaVersion": 1,
         "servers": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "A", "host": "a"}]}
        """
    let library = try LibraryCodec.decode(Data(json.utf8), migrations: migrations, currentVersion: 3)
    #expect(library.connections.map(\.name) == ["A"])
    #expect(library.folders.map(\.name) == ["Imported"])
    #expect(library.unknownFields.isEmpty)
}

@Test func missingMigrationIsAnError() {
    let json = #"{"schemaVersion": 1}"#
    #expect(throws: LibraryCodec.CodecError.noMigration(from: 1)) {
        try LibraryCodec.decode(Data(json.utf8), migrations: [:], currentVersion: 2)
    }
}

@Test func filesWithoutAVersionAreRejected() {
    #expect(throws: LibraryCodec.CodecError.missingSchemaVersion) {
        try LibraryCodec.decode(Data(#"{"connections": []}"#.utf8))
    }
    #expect(throws: LibraryCodec.CodecError.notAnObject) {
        try LibraryCodec.decode(Data("[]".utf8))
    }
}
