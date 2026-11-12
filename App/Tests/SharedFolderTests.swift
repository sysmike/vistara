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
