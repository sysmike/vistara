import Foundation
import Testing

@testable import RDPKit

/// Locking ([MS-RDPECLIP] 2.2.4.6 and 2.2.4.7) against the test server: a
/// copy on either side in the middle of a fetch does not spoil it. In the same
/// suite as the other file tests, which read the same server log.
extension FileClipboardIntegrationTests {
    /// Waits until the server's clipboard lines since `before` hold `line`.
    private func waitForServer(_ line: String, after before: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, !Self.clipboardLines(after: before).contains(line) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func aFetchGoesOnWhenTheRemoteComputerCopiesSomethingElse() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        // A file of this name asks the server to copy something else during
        // the next fetch of its report.
        let trigger = try scratch.file("copy something else while I fetch.txt", "x")
        try await whileConnected { session in
            let list = try #require(
                await first(of: session.remoteClipboardFiles, within: .seconds(10)) { !$0.isEmpty }
            )
            let asked = Self.serverLog().count
            session.send([.clipboardFiles(RDPLocalFileOffer(urls: [trigger]))])
            try await waitForServer("client-files-done", after: asked)

            let before = Self.serverLog().count
            let urls = try await session.fetchFiles(
                [list.files[0]], from: list, into: scratch.url.appendingPathComponent("Fetched")
            )

            let report = try Data(contentsOf: urls[0])
            #expect(UInt64(report.count) == Self.reportSize)
            let isExact = report.enumerated().allSatisfy { $0.element == Self.reportByte(UInt64($0.offset)) }
            #expect(isExact)
            let lines = Self.clipboardLines(after: before)
            #expect(lines.contains("copied-during-fetch"))
            // Every part named the lock, which the fetch released at its end.
            let locked = try #require(lines.first { $0.hasPrefix("locked id=") })
            let id = locked.dropFirst("locked id=".count)
            let parts = lines.filter { $0.hasPrefix("file-request index=0 flags=2 ") }
            #expect(parts.count == 3)
            #expect(parts.allSatisfy { $0.hasSuffix(" lock=\(id)") })
            #expect(lines.contains("unlocked id=\(id)"))
            // The remote computer's new text arrived, and its files left the clipboard.
            let text = await first(of: session.remoteClipboard, within: .seconds(10)) {
                $0 == "Neuer Text aus dem Testserver"
            }
            #expect(text != nil)
            #expect(await first(of: session.remoteClipboardFiles, within: .seconds(10)) { $0.isEmpty } != nil)
        }
    }

    @Test func theServerKeepsWhatItLockedWhenTheMacCopiesSomethingElse() async throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let locked = Data((0..<2_621_447).map { Self.reportByte(UInt64($0) + 3) })
        let firstURL = try scratch.file("First/Copied.bin", locked)
        let secondURL = try scratch.file("Second/Copied.bin", Data((0..<2_621_447).map { _ in UInt8(0x5A) }))

        let before = Self.serverLog().count
        try await whileConnected { session in
            session.send([.clipboardFiles(RDPLocalFileOffer(urls: [firstURL]))])
            // As soon as the server has locked the first file and begun to
            // fetch it, the Mac copies another in its place.
            try await waitForServer("client-lock=7", after: before)
            session.send([.clipboardFiles(RDPLocalFileOffer(urls: [secondURL]))])
            try await waitForServer("client-files-done", after: before)
        }

        let lines = Self.clipboardLines(after: before)
        let copied = try #require(lines.firstIndex(of: "client-copied-during-fetch"))
        let done = try #require(lines.firstIndex(of: "client-files-done"))
        #expect(copied < done)
        let firstDone = String(format: "client-file-done index=0 bytes=2621447 fnv=%016llx", Self.fnv(locked))
        #expect(lines.contains(firstDone))
        #expect(!lines.contains { $0.hasPrefix("client-file-failed") })
    }
}
