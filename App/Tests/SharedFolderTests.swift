import Foundation
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// Shared folders inside the App Sandbox: chosen, kept with a bookmark, and
/// opened again for a session.
@Suite
@MainActor
struct SharedFolderTests {
    /// A new folder in the app's container, which the sandbox lets it use.
    private func makeFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-share-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func samePlace(_ path: String, _ url: URL) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
    }

    @Test
    func aChosenFolderOpensAgainThroughItsBookmark() throws {
        let url = try makeFolder("Transfer")
        let shared = try SharedFolderAccess.sharedFolder(for: url, readOnly: true)
        #expect(shared.bookmark != nil)
        #expect(shared.isReadOnly)

        let access = SharedFolderAccess([shared])
        defer { access.stop() }
        let folder = try #require(access.folders.first)
        #expect(access.folders.count == 1)
        #expect(folder.name == "Transfer")
        #expect(folder.isReadOnly)
        #expect(samePlace(folder.path, url))
        #expect(access.missing.isEmpty)
    }

    @Test
    func aFolderThatIsGoneIsNotShared() throws {
        let url = try makeFolder("Gone")
        let shared = try SharedFolderAccess.sharedFolder(for: url)
        try FileManager.default.removeItem(at: url)
        let withoutBookmark = Connection.SharedFolder(path: "/Users/alice/Transfer")

        let access = SharedFolderAccess([shared, withoutBookmark])
        #expect(access.folders.isEmpty)
        #expect(access.missing == [shared, withoutBookmark])
    }

    @Test
    func aFolderInItsPlaceKeepsItsBookmark() throws {
        let shared = try SharedFolderAccess.sharedFolder(for: makeFolder("Transfer"))
        let access = SharedFolderAccess([shared])
        defer { access.stop() }
        #expect(access.folders.count == 1)
        #expect(access.renewed.isEmpty)
    }

    @Test
    func aRenamedFolderIsSharedAndGetsAFreshBookmark() throws {
        let url = try makeFolder("Transfer")
        let shared = try SharedFolderAccess.sharedFolder(for: url, readOnly: true)
        let moved = url.deletingLastPathComponent().appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: url, to: moved)

        let access = SharedFolderAccess([shared])
        defer { access.stop() }
        let folder = try #require(access.folders.first)
        #expect(folder.name == "Renamed")
        #expect(samePlace(folder.path, moved))

        let renewal = try #require(access.renewed.first)
        #expect(access.renewed.count == 1)
        #expect(renewal.old == shared)
        #expect(samePlace(renewal.new.path, moved))
        #expect(renewal.new.isReadOnly)
        #expect(renewal.new.bookmark != nil && renewal.new.bookmark != shared.bookmark)

        // The fresh bookmark opens the folder in its new place, as it is.
        let again = SharedFolderAccess([renewal.new])
        defer { again.stop() }
        #expect(again.folders.map(\.name) == ["Renamed"])
        #expect(again.renewed.isEmpty)
    }

    @Test
    func theLibrarySavesARenewedFolder() async throws {
        let old = Connection.SharedFolder(path: "/Users/alice/Transfer", bookmark: Data([1]))
        let other = Connection.SharedFolder(path: "/Users/alice/Photos", bookmark: Data([2]), isReadOnly: true)
        let new = Connection.SharedFolder(path: "/Users/alice/Renamed", bookmark: Data([3]))
        var connection = Connection(name: "Build Server", host: "build01")
        connection.sharedFolders = [old, other]
        var library = Library()
        library.connections = [connection]
        let (model, directory) = try await temporaryLibrary(library)

        await model.renewSharedFolders(of: connection.id, [SharedFolderAccess.Renewal(old: old, new: new)])
        // A folder no longer in the connection is not brought back.
        let removed = Connection.SharedFolder(path: "/Users/alice/Old", bookmark: Data([4]))
        await model.renewSharedFolders(of: connection.id, [SharedFolderAccess.Renewal(old: removed, new: new)])
        #expect(model.library.connections.first?.sharedFolders == [new, other])

        let reopened = LibraryModel(store: ConnectionStore(directory: directory))
        await reopened.load()
        #expect(reopened.library.connections.first?.sharedFolders == [new, other])
    }

    @Test
    func aSessionUsesAndPassesOnRenewedFolders() throws {
        let url = try makeFolder("Transfer")
        var target = SessionTarget(name: "Build Server", host: "127.0.0.1", port: 1)
        target.sharedFolders = [try SharedFolderAccess.sharedFolder(for: url)]
        let moved = url.deletingLastPathComponent().appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: url, to: moved)
        let model = SessionModel(target: target, credentialStore: InMemoryCredentialStore())
        var passedOn: [SharedFolderAccess.Renewal] = []
        model.onRenewedSharedFolders = { passedOn = $0 }

        model.connect()
        model.abandonAttempt()
        #expect(passedOn.count == 1)
        #expect(model.target.sharedFolders == passedOn.map(\.new))
    }

    @Test
    func drivesWithTheSameFolderNameGetNumbers() throws {
        let first = try SharedFolderAccess.sharedFolder(for: makeFolder("Transfer"))
        let second = try SharedFolderAccess.sharedFolder(for: makeFolder("transfer"))
        let access = SharedFolderAccess([first, second])
        defer { access.stop() }
        #expect(access.folders.map(\.name) == ["Transfer", "transfer 2"])
    }

    @Test
    func theEditorShowsTheHomeFolderAsATilde() throws {
        let home = try #require(getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) })
        #expect(SharedFolderRow.displayPath(home + "/Transfer") == "~/Transfer")
        #expect(SharedFolderRow.displayPath(home) == "~")
        #expect(SharedFolderRow.displayPath("/Volumes/Data") == "/Volumes/Data")
        #expect(SharedFolderRow.displayPath(home + "Else") == home + "Else")
    }

    @Test
    func theDraftSharesEachFolderOnceAndCanStop() throws {
        var draft = ConnectionDraft()
        draft.host = "build01"
        let transfer = Connection.SharedFolder(path: "/Users/alice/Transfer", bookmark: Data([1]))
        let photos = Connection.SharedFolder(path: "/Users/alice/Photos", bookmark: Data([2]), isReadOnly: true)
        draft.share([transfer, photos, transfer])
        #expect(draft.sharedFolders == [transfer, photos])
        #expect(draft.connection()?.sharedFolders == [transfer, photos])

        draft.stopSharing(transfer.path)
        #expect(draft.connection()?.sharedFolders == [photos])
        #expect(SessionTarget(connection: try #require(draft.connection())).sharedFolders == [photos])
    }

    /// The whole way, inside the sandbox: the test server writes a file into
    /// the shared folder.
    @Test(.enabled(if: TestServer.isFreeRDPTestServer), .timeLimit(.minutes(1)))
    func theRemoteComputerCanWriteIntoASharedFolder() async throws {
        let server = try #require(TestServer.current)
        let url = try makeFolder("Transfer")
        try Data("Hello from the Mac\n".utf8).write(to: url.appendingPathComponent("hello.txt"))
        var target = server.address
        target.sharedFolders = [try SharedFolderAccess.sharedFolder(for: url)]
        let model = SessionModel(target: target, credentialStore: try server.storeWithCredentials())

        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.trustOnce)
        let written = url.appendingPathComponent("from-server.txt")
        await waitUntil("the test server has written into the folder", within: .seconds(30)) {
            FileManager.default.fileExists(atPath: written.path)
        }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }
}
