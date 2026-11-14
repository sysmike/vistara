import AppKit
import RDPKit
import RDPKitUI
import Testing
@testable import Vistara

/// Copying files both ways with a real session against the test server, and
/// the CI pasteboard helper as the Finder (scripts/test-pasteboard). The
/// server offers a file list and fetches the files a client offers
/// (docs/DEVELOPING.md, Integration tests).
@Suite(
    .serialized,
    .enabled(if: TestServer.isFreeRDPTestServer && PasteboardHelper.isAvailable, "Needs the test server and helper")
)
@MainActor
struct FileClipboardSessionTests {
    /// Other tests' sessions put the server's text on the pasteboard when
    /// they connect, so a step whose pasteboard changed under it is tried again.
    private static let attempts = 3
    /// The server's report: larger than three of the client's parts.
    private static let reportSize = 2_621_440 + 123

    /// A session to the test server that copies files, once connected.
    private func connect() async throws -> RDPSession {
        let server = try #require(TestServer.current)
        var target = server.target
        target.copiesFiles = true
        let configuration = target.configuration(desktop: DesktopSize(width: 1024, height: 768, scalePercent: 100))
        let account = RDPCredentials(username: target.username, domain: target.domain, password: server.password)
        let session = RDPSession(
            configuration: configuration,
            delegate: RDPSessionDelegate(credentials: { _ in account }, certificateDecision: { _ in true })
        )
        session.start()
        for await state in session.states {
            if case .connected = state { return session }
            if case .disconnected = state { break }
        }
        throw CocoaError(.featureUnsupported)
    }

    /// The test server's clipboard lines since `before` lines, without their marker.
    private static func serverLines(after before: Int = 0) -> [String] {
        guard let path = ProcessInfo.processInfo.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        let lines = log.split(separator: "\n").map(String.init)
        return lines.dropFirst(before).compactMap { line in
            line.range(of: "vistara-clipboard ").map { String(line[$0.upperBound...]) }
        }
    }

    private static var serverLineCount: Int {
        guard let path = ProcessInfo.processInfo.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return 0 }
        return log.split(separator: "\n").count
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    @Test(.timeLimit(.minutes(2)))
    func theRemoteComputersFilesArePastedInTheFinder() async throws {
        let session = try await connect()
        defer { session.disconnect() }
        var lists = session.remoteClipboardFiles.makeAsyncIterator()
        var list: RDPRemoteFiles?
        while list?.isEmpty ?? true, let next = await lists.next() {
            list = next
        }
        let remote = try #require(list)
        let files = RemoteFilePaste(computerName: "Test Server") { items, list, folder, progress in
            try await session.fetchFiles(items, from: list, into: folder, progress: progress)
        }
        files.showProgress = { _ in }
        let bridge = ClipboardBridge(send: { _ in }, isInFront: { false }, files: files)
        defer { bridge.stop() }

        var pasted: [[String: Any]] = []
        for _ in 0..<Self.attempts {
            bridge.receive(remote)
            let result = try await PasteboardHelper.run("read-urls")
            pasted = result["files"] as? [[String: Any]] ?? []
            if !pasted.isEmpty { break }
        }
        PasteboardHelper.report("remote-files", ["files": pasted])

        #expect(pasted.compactMap { $0["name"] as? String } == ["Server Report.bin", "Server Folder"])
        #expect(pasted.first?["size"] as? Int == Self.reportSize)
        // Written by the sandboxed app, so marked as downloaded.
        #expect(pasted.first?["quarantined"] as? Bool == true)
        let inner = try FileManager.default.subpathsOfDirectory(atPath: files.folder.path)
            .first { $0.hasSuffix("Server Folder/Grüße ✓.txt") }
        let text = try inner.map { try String(contentsOf: files.folder.appendingPathComponent($0), encoding: .utf8) }
        #expect(text == "Inhalt aus dem Testserver\r\n")
    }

    @Test(.timeLimit(.minutes(2)))
    func filesCopiedInTheFinderArePastedOnTheRemoteComputer() async throws {
        let session = try await connect()
        defer { session.disconnect() }
        let files = RemoteFilePaste(computerName: "Test Server") { _, _, _, _ in [] }
        let bridge = ClipboardBridge(send: { session.send($0) }, isInFront: { true }, files: files)
        defer { bridge.stop() }

        let before = Self.serverLineCount
        for _ in 0..<Self.attempts {
            _ = try await PasteboardHelper.run("copy")
            bridge.checkMacClipboard()
            await bridge.waitUntilOffered()
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline, !Self.serverLines(after: before).contains("client-files-done") {
                try await Task.sleep(for: .milliseconds(100))
            }
            if Self.serverLines(after: before).contains("client-files-done") { break }
        }

        let lines = Self.serverLines(after: before)
        PasteboardHelper.report("mac-files", ["lines": lines.filter { $0.hasPrefix("client-") }])
        #expect(lines.contains("client-list count=3"))
        #expect(lines.contains("client-file index=0 folder=0 size=17 name=\(Self.hex("Report.txt"))"))
        #expect(lines.contains("client-file index=1 folder=1 size=0 name=\(Self.hex("Folder"))"))
        #expect(lines.contains("client-file index=2 folder=0 size=18 name=\(Self.hex("Folder\\Inner.txt"))"))
        #expect(lines.contains { $0.hasPrefix("client-file-done index=0 bytes=17 ") })
        #expect(lines.contains { $0.hasPrefix("client-file-done index=2 bytes=18 ") })
        #expect(!lines.contains { $0.hasPrefix("client-file-failed") })
    }
}
