import Foundation
import Testing

@testable import RDPKit

/// The keyboard reaches the server in the client core data; the test server
/// logs what it received.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(1)))
struct KeyboardLayoutIntegrationTests {
    static func keyboardsTheServerSaw() -> [String] {
        guard let path = TestHost.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").compactMap { line in
            line.range(of: "vistara-keyboard ").map { String(line[$0.upperBound...]) }
        }
    }

    /// Connects with `keyboard` and returns whether the server logged
    /// `expected`. Other suites connect at the same time and log lines of
    /// their own, so the line is looked for, not taken as the last one.
    private func serverSaw(_ expected: String, connectingWith keyboard: RDPKeyboard) throws -> Bool {
        let before = Self.keyboardsTheServerSaw().count
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.keyboard = keyboard
        #expect(handle.connect(to: target) { _ in true } == .connected)
        defer { handle.disconnect() }
        // The server logs while the connection is set up; give the line a moment.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.keyboardsTheServerSaw().dropFirst(before).contains(expected) { return true }
            _ = handle.poll(timeoutMilliseconds: 100)
        }
        return false
    }

    @Test func theServerReceivesTheMacsLayout() throws {
        #expect(try serverSaw("layout=0x00000407 type=4 subtype=0", connectingWith: RDPKeyboard(layout: 0x0407)))
    }

    @Test func aJapaneseKeyboardArrivesAsOne() throws {
        let japanese = RDPKeyboard(layout: 0x0411, type: 7, subtype: 2, functionKeys: 12)
        #expect(try serverSaw("layout=0x00000411 type=7 subtype=2", connectingWith: japanese))
    }
}
