import AppKit
import Foundation
import Testing
import VistaraCore
@testable import Vistara

@Suite(.serialized)
@MainActor
struct ImportExportTests {
    /// Writes `.rdp` files into a folder of their own.
    private func files(_ contents: [String: String]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-rdp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try contents.keys.sorted().map { name in
            let url = folder.appendingPathComponent(name)
            try Data(contents[name, default: ""].utf8).write(to: url)
            return url
        }
    }

    @Test
    func importingAFileAddsAConnectionNamedAfterIt() async throws {
        let (model, _) = try await temporaryLibrary()
        let urls = try files([
            "Build Server.rdp": """
                full address:s:build01.example.com:3390
                username:s:EXAMPLE\\alice
                password 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB
                this line is not a setting
                audiomode:i:2
                """
        ])
        let report = await model.importRDPFiles(urls)

        let connection = try #require(model.library.connections.first)
        #expect(model.library.connections.count == 1)
        #expect(connection.name == "Build Server")
        #expect(connection.host == "build01.example.com")
        #expect(connection.port == 3390)
        #expect(connection.username == "alice")
        #expect(connection.domain == "EXAMPLE")
        #expect(connection.audioMode == .off)
        #expect(model.selectedIDs == [connection.id])
        #expect(report.imported == ["Build Server"])
        #expect(report.droppedPasswords == ["Build Server"])
        #expect(report.skippedLines == 1)
        #expect(model.importReport == report)
    }

    @Test
    func aFileWithoutAComputerIsReportedAndNotAdded() async throws {
        let (model, _) = try await temporaryLibrary()
        let report = await model.importRDPFiles(try files(["Empty.rdp": "username:s:alice\n"]))
        #expect(model.library.connections.isEmpty)
        #expect(report.failures == ["“Empty.rdp” names no computer and wasn’t imported."])
        #expect(report.sentences == report.failures)
    }

    @Test
    func theNoticeSaysWhatHappenedInWords() {
        let report = ImportReport(
            imported: ["Build Server", "Jump Host"], droppedPasswords: ["Build Server"], skippedLines: 3, failures: []
        )
        #expect(report.sentences == [
            "Imported 2 connections.",
            "The password in “Build Server” was not imported; Vistara asks for it when connecting.",
            "3 lines that aren’t settings were skipped."
        ])
    }

    @Test
    func anExportedFileIsWhatTheMicrosoftClientWritesAndImportsBack() async throws {
        var connection = Connection(name: "Build Server", host: "build01.example.com")
        connection.port = 3390
        connection.username = "alice"
        connection.domain = "EXAMPLE"
        let data = RDPFileMapping.file(from: connection).data
        // UTF-16 little-endian with a byte order mark, Windows line endings.
        #expect(data.prefix(2) == Data([0xFF, 0xFE]))
        let text = try #require(String(data: data.dropFirst(2), encoding: .utf16LittleEndian))
        #expect(text.contains("full address:s:build01.example.com:3390\r\n"))
        #expect(!text.lowercased().contains("password"))
        #expect(RDPDocument.fileName(for: connection) == "Build Server.rdp")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(RDPDocument.fileName(for: connection))
        try data.write(to: url)
        let (model, _) = try await temporaryLibrary()
        await model.importRDPFiles([url])
        let imported = try #require(model.library.connections.first)
        #expect(imported.name == "Build Server")
        #expect(imported.host == connection.host)
        #expect(imported.port == connection.port)
        #expect(imported.username == connection.username)
        #expect(imported.domain == connection.domain)
    }

    @Test
    func aFileOpenedBeforeTheLibraryLoadedIsImportedOnceItHas() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-library-\(UUID().uuidString)", isDirectory: true)
        let model = LibraryModel(store: ConnectionStore(directory: directory))
        await model.importWhenLoaded(try files(["Lab.rdp": "full address:s:lab01\n"]))
        #expect(model.library.connections.isEmpty)
        await model.load()
        #expect(model.library.connections.map(\.name) == ["Lab"])
    }

    /// After an import that dropped a password, skipped lines, and missed a file.
    @Test(arguments: [false, true])
    func importNotice(dark: Bool) async throws {
        let report = ImportReport(
            imported: ["Build Server"], droppedPasswords: ["Build Server"], skippedLines: 2,
            failures: ["“Notes.rdp” names no computer and wasn’t imported."]
        )
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        model.importReport = report
        let view = ConnectionsView(model: model) { _, _ in }
        let name = dark ? "import-notice-dark" : "import-notice"
        let bytes = try await Screenshots.write(
            view, size: NSSize(width: 780, height: 460), name: name, dark: dark, frame: .window(title: "Connections")
        )
        #expect(bytes > 0)
    }

    /// After a load that left out an unreadable connection (issue #51).
    @Test
    func skippedEntriesNotice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = """
            {"schemaVersion": 1, "connections": [
                {"id": "\(UUID().uuidString)", "name": "Build Server", "host": "build01.example.com"},
                {"name": "Broken"}
            ]}
            """
        try Data(contents.utf8).write(to: directory.appendingPathComponent(ConnectionStore.fileName))
        let model = LibraryModel(store: ConnectionStore(directory: directory))
        await model.load()
        let view = ConnectionsView(model: model) { _, _ in }
        let bytes = try await Screenshots.write(
            view, size: NSSize(width: 780, height: 460), name: "skipped-notice", frame: .window(title: "Connections")
        )
        #expect(bytes > 0)
    }
}
