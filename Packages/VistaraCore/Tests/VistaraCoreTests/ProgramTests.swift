import Foundation
import Testing

@testable import VistaraCore

/// Connections that open a program in place of the desktop (#153).
@Suite
struct ProgramModelTests {
    @Test func aConnectionFromAnOlderFileOpensTheDesktop() throws {
        let json = #"{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "A", "host": "a"}"#
        let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        #expect(connection.program == Connection.Program())
        #expect(connection.program.opens == .desktop)
        #expect(!connection.program.isUsed)
        #expect(connection.programIcon == nil)
    }

    @Test func theProgramAndItsIconSurviveSavingAndLoading() throws {
        var connection = Connection(name: "Word", host: "apps01")
        connection.program = .init(opens: .program, path: "||WINWORD", arguments: "/safe")
        connection.programIcon = Data([0x89, 0x50, 0x4E, 0x47])
        let library = Library(connections: [connection])
        #expect(try LibraryCodec.decode(LibraryCodec.encode(library)) == library)
    }

    @Test func usedOnlyWhenAProgramIsChosenAndNamed() {
        #expect(Connection.Program(opens: .program, path: "||WINWORD").isUsed)
        #expect(!Connection.Program(opens: .program, path: "  ").isUsed)
        #expect(!Connection.Program(opens: .desktop, path: "||WINWORD").isUsed)
    }

    @Test func theIconStaysOnEachMacThroughASyncFolder() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        var connection = Connection(name: "Word", host: "apps01")
        connection.program = .init(opens: .program, path: "||WINWORD")
        connection.programIcon = Data([1, 2, 3])
        _ = try await macs.first.save(Library(connections: [connection]))

        let theirs = try await macs.second.sync().library
        #expect(theirs.connections.first?.program == connection.program)
        #expect(theirs.connections.first?.programIcon == nil)
        let file = try Data(contentsOf: macs.file("connections", connection.id))
        #expect(String(bytes: file, encoding: .utf8)?.contains("programIcon") == false)

        // An icon of its own on the second Mac changes nothing shared.
        var mine = theirs
        mine.connections[0].programIcon = Data([4, 5, 6])
        _ = try await macs.second.save(mine)
        #expect(try Data(contentsOf: macs.file("connections", connection.id)) == file)
        #expect(try await macs.first.sync().library.connections.first?.programIcon == Data([1, 2, 3]))
    }
}

@Suite
struct ProgramRDPFileTests {
    private func connection(_ text: String, name: String = "File Name") throws -> Connection {
        try RDPFileMapping.connection(from: RDPFile(text: "full address:s:apps01\n" + text), name: name)
    }

    @Test func theMicrosoftClientsLinesImport() throws {
        let imported = try connection("""
            remoteapplicationmode:i:1
            remoteapplicationprogram:s:||WINWORD
            remoteapplicationname:s:Microsoft Word
            remoteapplicationcmdline:s:/safe
            remoteapplicationicon:s:C:\\icons\\word.ico
            """)
        #expect(imported.program == .init(opens: .program, path: "||WINWORD", arguments: "/safe"))
        #expect(imported.name == "Microsoft Word")
        // Lines Vistara has no setting for stay as written.
        #expect(imported.additionalRDPSettings == ["remoteapplicationicon:s:C:\\icons\\word.ico"])
    }

    @Test func withoutANameTheFileNameStays() throws {
        let imported = try connection("remoteapplicationmode:i:1\nremoteapplicationprogram:s:||calc")
        #expect(imported.program.isUsed)
        #expect(imported.name == "File Name")
    }

    @Test func aModeWithoutAProgramOpensTheDesktopAndSaysSo() throws {
        let text = "full address:s:apps01\nremoteapplicationmode:i:1\nremoteapplicationname:s:Word"
        let file = RDPFile(text: text)
        let imported = try RDPFileMapping.connection(from: file, name: "File Name")
        #expect(imported.program.opens == .desktop)
        #expect(imported.name == "File Name")
        #expect(RDPFileMapping.asksForAProgramWithoutOne(file))
        #expect(!RDPFileMapping.asksForAProgramWithoutOne(RDPFile(text: "full address:s:pc")))
    }

    @Test func aProgramWithTheModeOffIsKeptButOpensTheDesktop() throws {
        let imported = try connection("remoteapplicationmode:i:0\nremoteapplicationprogram:s:||WINWORD")
        #expect(imported.program == .init(opens: .desktop, path: "||WINWORD"))
    }

    @Test func aDesktopWritesNoProgramLines() {
        var connection = Connection(name: "Build", host: "build01")
        connection.program = .init(opens: .desktop, path: "||WINWORD")
        let keys = RDPFileMapping.file(from: connection).settings.map(\.key)
        #expect(!keys.contains { $0.hasPrefix("remoteapplication") })
    }

    @Test func aProgramSurvivesExportAndImport() throws {
        var connection = Connection(name: "Microsoft Word", host: "apps01")
        connection.program = .init(opens: .program, path: "||WINWORD", arguments: "/safe")
        let file = RDPFileMapping.file(from: connection)
        #expect(file.integer("remoteapplicationmode") == 1)
        #expect(file.string("remoteapplicationprogram") == "||WINWORD")
        #expect(file.string("remoteapplicationname") == "Microsoft Word")
        #expect(file.string("remoteapplicationcmdline") == "/safe")

        let back = try RDPFileMapping.connection(from: RDPFile(text: file.text), name: "Exported")
        #expect(back.program == connection.program)
        #expect(back.name == "Microsoft Word")
    }

    @Test func noArgumentsWritesNoCommandLine() {
        var connection = Connection(name: "Calculator", host: "apps01")
        connection.program = .init(opens: .program, path: "||calc")
        #expect(RDPFileMapping.file(from: connection).string("remoteapplicationcmdline") == nil)
    }
}
