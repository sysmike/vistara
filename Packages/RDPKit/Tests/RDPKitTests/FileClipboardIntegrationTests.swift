import Foundation
import Testing
import os

@testable import RDPKit

/// Files through the clipboard against the test server, which offers a file
/// list, serves its files in parts, and fetches and reports the files a
/// client offers (scripts/test-server/sample-screen.patch).
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(3)))
struct FileClipboardIntegrationTests {
    /// The server's report: larger than three of the client's parts.
    static let reportSize: UInt64 = 2_621_440 + 123

    static func reportByte(_ offset: UInt64) -> UInt8 {
        UInt8(truncatingIfNeeded: offset &* 31 &+ (offset >> 16))
    }

    /// The server's list as the Mac sees it: "Q1/Q2.txt" lists no size, and
    /// "\Absolute.txt" is left out.
    static let serverFiles = [
        RDPClipboardFile(path: "Server Report.bin", size: reportSize, isFolder: false),
        RDPClipboardFile(path: "Server Folder", size: 0, isFolder: true),
        RDPClipboardFile(path: "Server Folder/Grüße ✓.txt", size: 27, isFolder: false),
        RDPClipboardFile(path: "Server Folder/Q1:Q2.txt", size: 0, isFolder: false)
    ]

    static func serverLog() -> [String] {
        guard let path = TestHost.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").map(String.init)
    }

    /// The server's clipboard lines since `before` lines, without their marker.
    static func clipboardLines(after before: Int) -> [String] {
        serverLog().dropFirst(before).compactMap { line in
            line.range(of: "vistara-clipboard ").map { String(line[$0.upperBound...]) }
        }
    }

    static func fnv(_ data: Data) -> UInt64 {
        data.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    static func hexDecoded(_ hex: some StringProtocol) -> [UInt8] {
        let digits = Array(hex)
        return stride(from: 0, to: digits.count - 1, by: 2).compactMap { index in
            UInt8(String(digits[index...index + 1]), radix: 16)
        }
    }

    /// Starts a session that shares the clipboard, runs `body` once it is
    /// connected, and ends it. Returns the ended session.
    @discardableResult
    private func whileConnected(
        copiesFiles: Bool = true, _ body: (RDPSession) async throws -> Void
    ) async throws -> RDPSession {
        var configuration = TestHost.configuration
        configuration.sharesClipboard = true
        configuration.copiesFiles = copiesFiles
        let session = RDPSession(configuration: configuration, delegate: TestHost.delegate())
        session.start()
        var states = session.states.makeAsyncIterator()
        var isConnected = false
        while !isConnected, let state = await states.next() {
            if case .connected = state { isConnected = true }
        }
        try #require(isConnected)
        do {
            try await body(session)
        } catch {
            session.disconnect()
            while await states.next() != nil {}
            throw error
        }
        session.disconnect()
        while await states.next() != nil {}
        return session
    }

    @Test func theServersFilesArriveAsNamesAndAreFetchedOnRequest() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try await whileConnected { session in
            let list = try #require(
                await first(of: session.remoteClipboardFiles, within: .seconds(10)) { !$0.isEmpty }
            )
            #expect(list.files == Self.serverFiles)
            #expect(list.skippedCount == 1)
            #expect(list.topLevel.map(\.path) == ["Server Report.bin", "Server Folder"])
            // The text it offers too still arrives.
            let text = await first(of: session.remoteClipboard, within: .seconds(10)) { _ in true }
            #expect(text == ClipboardIntegrationTests.serverText)

            let before = Self.serverLog().count
            let progress = Reports()
            let urls = try await session.fetchFiles(list.topLevel, from: list, into: scratch.url) {
                progress.append($0)
            }

            #expect(urls == [scratch.url.appendingPathComponent("Server Report.bin"),
                             scratch.url.appendingPathComponent("Server Folder")])
            let report = try Data(contentsOf: urls[0])
            #expect(UInt64(report.count) == Self.reportSize)
            let isExact = report.enumerated().allSatisfy { $0.element == Self.reportByte(UInt64($0.offset)) }
            #expect(isExact)
            let folder = urls[1]
            #expect(try String(contentsOf: folder.appendingPathComponent("Grüße ✓.txt"), encoding: .utf8)
                == "Inhalt aus dem Testserver\r\n")
            #expect(try String(contentsOf: folder.appendingPathComponent("Q1:Q2.txt"), encoding: .utf8)
                == "Ohne Größe\r\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).sorted()
                == ["Server Folder", "Server Report.bin"])

            let total = Self.reportSize + 27 + 14
            #expect(progress.last == RDPFileFetchProgress(
                bytesReceived: total, bytesExpected: total, filesDone: 3, fileCount: 3))
            // The report came in parts of 1 MiB; the unsized file's size was asked for.
            let requests = Self.clipboardLines(after: before).filter { $0.hasPrefix("file-request ") }
            #expect(requests.filter { $0.hasPrefix("file-request index=0 flags=2 ") }.count == 3)
            #expect(requests.contains { $0.hasPrefix("file-request index=3 flags=1 ") })
            #expect(!requests.contains { $0.hasPrefix("file-request index=4 ") })
        }
    }

    @Test func cancellingAFetchRemovesTheFileItWasWriting() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try await whileConnected { session in
            let list = try #require(
                await first(of: session.remoteClipboardFiles, within: .seconds(10)) { !$0.isEmpty }
            )
            let report = list.files[0]
            let (arrived, arrival) = AsyncStream.makeStream(of: Void.self)
            let firstFolder = scratch.url.appendingPathComponent("First")
            let fetch = Task {
                try await session.fetchFiles([report], from: list, into: firstFolder) { progress in
                    if progress.bytesReceived > 0 { arrival.yield() }
                }
            }
            #expect(await first(of: arrived, within: .seconds(10)) { _ in true } != nil)
            fetch.cancel()

            await #expect(throws: CancellationError.self) { try await fetch.value }
            let partial = scratch.url.appendingPathComponent("First/Server Report.bin")
            #expect(!FileManager.default.fileExists(atPath: partial.path))

            // The next fetch works.
            let thenFolder = scratch.url.appendingPathComponent("Then")
            let urls = try await session.fetchFiles([report], from: list, into: thenFolder)
            let size = try FileManager.default.attributesOfItem(atPath: urls[0].path)[.size] as? NSNumber
            #expect(size?.uint64Value == Self.reportSize)
        }
    }

    @Test func filesFromTheMacReachTheServerWithoutSymbolicLinks() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let large = Data((0..<2_621_447).map { Self.reportByte(UInt64($0) + 1) })
        let report = try scratch.file("Mac Report.bin", large)
        let note = try scratch.file("Mac Folder/Notiz ✓.txt", "Hallo vom Mac\n")
        try scratch.folder("Mac Folder/Empty")
        try scratch.link("Mac Folder/Link.txt", to: "../Mac Report.bin")
        let offer = RDPLocalFileOffer(urls: [report, scratch.url.appendingPathComponent("Mac Folder")])
        #expect(offer.skippedCount == 1)

        let before = Self.serverLog().count
        try await whileConnected { session in
            session.send([.clipboardFiles(offer)])
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !Self.clipboardLines(after: before).contains("client-files-done") {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        let lines = Self.clipboardLines(after: before)
        #expect(lines.contains("client-list count=4"))
        let listed = lines.filter { $0.hasPrefix("client-file index=") }.map { line in
            let parts = line.split(separator: " name=", maxSplits: 1)
            let name = String(bytes: Self.hexDecoded(parts.count > 1 ? parts[1] : ""), encoding: .utf8) ?? ""
            return "\(parts[0].dropFirst("client-file ".count)) \(name)"
        }
        #expect(listed == [
            "index=0 folder=0 size=2621447 Mac Report.bin",
            "index=1 folder=1 size=0 Mac Folder",
            "index=2 folder=1 size=0 Mac Folder\\Empty",
            "index=3 folder=0 size=14 Mac Folder\\Notiz ✓.txt"
        ])
        let noteData = try Data(contentsOf: note)
        let largeDone = String(format: "client-file-done index=0 bytes=2621447 fnv=%016llx", Self.fnv(large))
        let noteDone = String(format: "client-file-done index=3 bytes=14 fnv=%016llx", Self.fnv(noteData))
        #expect(lines.contains(largeDone))
        #expect(lines.contains(noteDone))
        #expect(!lines.contains { $0.hasPrefix("client-file-failed") })
        // A folder has no contents to read, and nothing beyond the list is read.
        #expect(lines.contains("client-refused what=folder ok=0"))
        #expect(lines.contains("client-refused what=beyond ok=0"))
    }

    @Test func withoutCopyingFilesNoFilePassesEitherWay() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let offer = RDPLocalFileOffer(urls: [try scratch.file("Private.txt", "must not leave the Mac\n")])

        // The server's list as if it had arrived: the session still fetches nothing.
        let madeUp = RDPRemoteFiles(files: Self.serverFiles, skippedCount: 0, listID: 1, listIndices: [0, 1, 2, 3])
        let before = Self.serverLog().count
        let session = try await whileConnected(copiesFiles: false) { session in
            session.send([.clipboardFiles(offer)])
            // Text still passes.
            let text = await first(of: session.remoteClipboard, within: .seconds(10)) { _ in true }
            #expect(text == ClipboardIntegrationTests.serverText)
            let inside = scratch.url.appendingPathComponent("In")
            await #expect(throws: RDPFileFetchError.noLongerOnClipboard) {
                try await session.fetchFiles([madeUp.files[0]], from: madeUp, into: inside)
            }
            try await Task.sleep(for: .seconds(2))
        }

        var lists: [RDPRemoteFiles] = []
        for await list in session.remoteClipboardFiles { lists.append(list) }
        #expect(lists.isEmpty)
        let lines = Self.clipboardLines(after: before)
        #expect(!lines.contains { $0.hasPrefix("client-list") || $0.hasPrefix("file-request") })
        // After the session: it has ended.
        await #expect(throws: RDPFileFetchError.sessionEnded) {
            try await session.fetchFiles([madeUp.files[0]], from: madeUp, into: scratch.url)
        }
    }
}

/// Progress reports, gathered from the session thread.
final class Reports: Sendable {
    private let reports = OSAllocatedUnfairLock<[RDPFileFetchProgress]>(initialState: [])

    func append(_ report: RDPFileFetchProgress) { reports.withLock { $0.append(report) } }
    var last: RDPFileFetchProgress? { reports.withLock { $0.last } }
}

/// The first element of `stream` that `matches`, or nil after `timeout`.
func first<Element: Sendable>(
    of stream: AsyncStream<Element>, within timeout: Duration, where matches: @escaping @Sendable (Element) -> Bool
) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream where matches(element) { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let found = await group.next() ?? nil
        group.cancelAll()
        return found
    }
}
