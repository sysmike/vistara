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

    private func connect(_ keyboard: RDPKeyboard?) throws -> String? {
        let before = Self.keyboardsTheServerSaw().count
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.keyboard = keyboard
        #expect(handle.connect(to: target) { _ in true } == .connected)
        defer { handle.disconnect() }
        // The server logs while the connection is set up; give the line a moment.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let seen = Self.keyboardsTheServerSaw().dropFirst(before).last { return seen }
            _ = handle.poll(timeoutMilliseconds: 100)
        }
        return nil
    }

    @Test func theServerReceivesTheMacsLayout() throws {
        #expect(try connect(RDPKeyboard(layout: 0x0407)) == "layout=0x00000407 type=4 subtype=0")
    }

    @Test func aJapaneseKeyboardArrivesAsOne() throws {
        let japanese = RDPKeyboard(layout: 0x0411, type: 7, subtype: 2, functionKeys: 12)
        #expect(try connect(japanese) == "layout=0x00000411 type=7 subtype=2")
    }

    @Test func withoutALayoutTheServerDecides() throws {
        #expect(try connect(nil) == "layout=0x00000000 type=4 subtype=0")
    }
}
