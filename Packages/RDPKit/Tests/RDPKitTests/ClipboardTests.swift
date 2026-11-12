import Foundation
import Testing

@testable import RDPKit

@Suite
struct ClipboardTextTests {
    @Test func theMacsLineFeedsBecomeCarriageReturnLineFeeds() {
        #expect(RDPClipboardText.toRemote("a\nb\n") == "a\r\nb\r\n")
        // Already there: not doubled.
        #expect(RDPClipboardText.toRemote("a\r\nb") == "a\r\nb")
        #expect(RDPClipboardText.toRemote("Grüße ✓") == "Grüße ✓")
    }

    @Test func windowsLineEndingsBecomeLineFeeds() {
        #expect(RDPClipboardText.fromRemote("a\r\nb\rc\n") == "a\nb\nc\n")
        #expect(RDPClipboardText.fromRemote("") == "")
    }
}

/// The clipboard against the test server, which offers a known text and
/// reports what it receives.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(2)))
struct ClipboardIntegrationTests {
    /// What the test server offers, as the Mac sees it.
    static let serverText = "Grüße aus dem Testserver ✓\nZweite Zeile"

    /// Texts the test server received, decoded from the hex it logs.
    static func textsTheServerReceived() -> [String] {
        guard let path = TestHost.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: "vistara-clipboard from-client ") else { return nil }
            let hex = Array(line[marker.upperBound...])
            var bytes: [UInt8] = []
            var index = 0
            while index + 1 < hex.count, let byte = UInt8(String(hex[index...index + 1]), radix: 16) {
                bytes.append(byte)
                index += 2
            }
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map {
                UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
            }
            return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
        }
    }

    private func handle(sharing: Bool) throws -> SessionHandle {
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.sharesClipboard = sharing
        #expect(handle.connect(to: target) { _ in true } == .connected)
        return handle
    }

    @Test func theServersTextArrivesWithMacLineEndings() throws {
        let handle = try handle(sharing: true)
        defer { handle.disconnect() }
        var received: String?
        let deadline = Date().addingTimeInterval(10)
        while received == nil, Date() < deadline, handle.poll(timeoutMilliseconds: 100) {
            received = handle.takeRemoteClipboardText()
        }
        #expect(received == Self.serverText)
        #expect(handle.clipboardConnected)
    }

    @Test func textFromTheMacReachesTheServerWithWindowsLineEndings() async {
        let before = Self.textsTheServerReceived().count
        var configuration = TestHost.configuration
        configuration.sharesClipboard = true
        let session = RDPSession(configuration: configuration, delegate: TestHost.delegate())
        var received: [String] = []
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            session.send([.clipboardText("Héllo, Welt ✓\nzweite Zeile")])
            let deadline = Date().addingTimeInterval(10)
            while received.isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                received = Array(Self.textsTheServerReceived().dropFirst(before))
            }
            session.disconnect()
        }
        #expect(received == ["Héllo, Welt ✓\r\nzweite Zeile"])
    }

    @Test func withSharingOffNothingPassesEitherWay() throws {
        let before = Self.textsTheServerReceived().count
        let handle = try handle(sharing: false)
        defer { handle.disconnect() }
        _ = handle.send(.clipboardText("must not leave the Mac"))
        var received: String?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, handle.poll(timeoutMilliseconds: 100) {
            received = received ?? handle.takeRemoteClipboardText()
        }
        #expect(!handle.clipboardConnected)
        #expect(handle.clipboardBytesSent == 0)
        #expect(received == nil)
        #expect(Self.textsTheServerReceived().count == before)
    }
}
