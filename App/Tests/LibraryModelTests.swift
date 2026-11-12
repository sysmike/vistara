import Foundation
import Testing
import VistaraCore
@testable import Vistara

@Suite(.serialized)
@MainActor
struct LibraryModelTests {
    private func names(_ model: LibraryModel) -> [String] {
        model.visibleConnections.map(\.name)
    }

    @Test
    func anEmptyFolderGivesAnEmptyLibrary() async throws {
        let (model, _) = try await temporaryLibrary()
        #expect(model.loadState == .loaded)
        #expect(model.library.connections.isEmpty)
        #expect(model.canChange)
    }

    @Test
    func addingSavesAndSurvivesARestart() async throws {
        let (model, directory) = try await temporaryLibrary()
        await model.add(Connection(name: "Build Server", host: "build01.example.com"))
        #expect(!model.saveFailed)

        let reopened = LibraryModel(store: ConnectionStore(directory: directory))
        await reopened.load()
        #expect(reopened.library.connections.map(\.host) == ["build01.example.com"])
    }

    @Test
    func theListIsSortedByNameAsPeopleRead() async throws {
        var library = Library()
        for name in ["server 10", "Server 2", "alpha"] {
            library.connections.append(Connection(name: name, host: "h"))
        }
        let (model, _) = try await temporaryLibrary(library)
        #expect(names(model) == ["alpha", "Server 2", "server 10"])
    }

    @Test
    func theSidebarSelectsFavoritesRecentsFoldersAndTags() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        #expect(names(model).count == 4)
        model.selection = .favorites
        #expect(names(model) == ["Build Server"])
        model.selection = .recents
        #expect(names(model) == ["Build Server", "Finance VM"])
        model.selection = .folder(SampleLibrary.lab.id)
        #expect(names(model) == ["Build Server", "Lab Desktop"])
        model.selection = .tag("PROD")
        #expect(names(model) == ["Build Server", "Finance VM"])
    }

    @Test
    func foldersAndTagsAreListedOnceInOrder() async throws {
        var library = SampleLibrary.library
        library.connections[2].tags.append(" Prod ")
        let (model, _) = try await temporaryLibrary(library)
        #expect(model.folders.map(\.name) == ["Lab", "Office"])
        #expect(model.tags == ["finance", "prod", "test"])
        #expect(model.title(for: .folder(SampleLibrary.office.id)) == "Office")
    }

    @Test
    func searchMatchesNameHostUserAndTagsEveryWord() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let searches: [String: [String]] = [
            "build": ["Build Server"],
            "10.0.4": ["Finance VM"],
            "OPS": ["Jump Host"],
            "finance": ["Finance VM"],
            "prod server": ["Build Server"],
            "example lab": ["Lab Desktop"],
            "nothing": [],
            "  ": ["Build Server", "Finance VM", "Jump Host", "Lab Desktop"]
        ]
        for (search, expected) in searches {
            model.searchText = search
            #expect(names(model) == expected, "\(search)")
        }
    }

    @Test
    func searchWorksWithinTheSelectedSection() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        model.selection = .folder(SampleLibrary.lab.id)
        model.searchText = "desktop"
        #expect(names(model) == ["Lab Desktop"])
    }

    @Test
    func usingAConnectionRecordsWhen() async throws {
        let (model, directory) = try await temporaryLibrary(SampleLibrary.library)
        let jump = try #require(model.library.connections.first { $0.name == "Jump Host" })
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        await model.recordConnection(jump.id, at: when)

        let reopened = LibraryModel(store: ConnectionStore(directory: directory))
        await reopened.load()
        #expect(reopened.library.connections.first { $0.id == jump.id }?.lastConnectedAt == when)
    }

    @Test
    func aLibraryFromANewerVistaraIsShownAsUnreadableAndNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(ConnectionStore.fileName)
        let newer = #"{"schemaVersion": 99, "connections": [], "folders": []}"#
        try Data(newer.utf8).write(to: file)

        let model = LibraryModel(store: ConnectionStore(directory: directory))
        await model.load()
        guard case .unreadable = model.loadState else {
            Issue.record("expected unreadable, got \(model.loadState)")
            return
        }
        #expect(!model.canChange)
        await model.add(Connection(name: "x", host: "x"))
        try #expect(String(contentsOf: file, encoding: .utf8) == newer)
    }

    @Test
    func aCorruptLibraryStartsOverAndSaysWhereTheOldFileIs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(ConnectionStore.fileName))

        let model = LibraryModel(store: ConnectionStore(directory: directory))
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(model.library.connections.isEmpty)
        #expect(model.corruptFileBackup?.lastPathComponent.hasPrefix("connections.corrupt-") == true)
    }

    // MARK: From a connection to a session

    @Test
    func aSessionFromTheLibraryUsesTheConnectionsOwnKeychainItem() {
        var connection = Connection(name: "", host: "Build01.example.com")
        connection.port = 3390
        connection.username = "alice"
        connection.domain = "CORP"
        connection.resolutionMode = .fixed
        connection.usesHiDPI = false
        let target = SessionTarget(connection: connection)
        #expect(target.name == "Build01.example.com")
        #expect(target.port == 3390)
        #expect(target.domain == "CORP")
        #expect(target.credentialKey == connection.id.uuidString)
        #expect(target.resolutionMode == .fixed)
        #expect(!target.usesHiDPI)

        // Without a saved connection, the address identifies the computer.
        let typed = SessionTarget(name: "h", host: "Host", port: 3389)
        #expect(typed.credentialKey == "host:3389")
    }

    @Test
    func lastUsedReadsAsTodayYesterdayOrADate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LastUsedFormat.string(for: nil, now: now, calendar: calendar) == "Never")
        #expect(LastUsedFormat.string(for: now.addingTimeInterval(-60), now: now, calendar: calendar) == "Today")
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(LastUsedFormat.string(for: yesterday, now: now, calendar: calendar) == "Yesterday")
        let older = LastUsedFormat.string(for: now.addingTimeInterval(-86_400 * 10), now: now, calendar: calendar)
        #expect(older != "Today" && older != "Yesterday" && !older.isEmpty)
    }
}
