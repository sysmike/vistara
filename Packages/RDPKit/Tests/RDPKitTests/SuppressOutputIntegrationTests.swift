import Foundation
import Testing

@testable import RDPKit

/// A session nobody can see asks the server to stop sending its screen, and
/// to send all of it again when it can be seen (#103). The test server logs
/// each Suppress Output PDU it receives.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(1)))
struct SuppressOutputIntegrationTests {
    static func pdusTheServerSaw() -> [String] {
        guard let path = TestHost.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").compactMap { line in
            line.range(of: "vistara-suppress ").map { String(line[$0.upperBound...]) }
        }
    }

    /// Polls until the server has logged `expected` after the first `skipping`
    /// lines. Other suites connect at the same time, but only this one sends
    /// Suppress Output.
    private func waitForServer(
        toSee expected: String, after skipping: Int, while handle: SessionHandle
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.pdusTheServerSaw().dropFirst(skipping).contains(expected) { return true }
            _ = handle.poll(timeoutMilliseconds: 100)
        }
        return false
    }

    @Test func hidingAndShowingASessionStopsAndResumesItsScreen() throws {
        let handle = try #require(SessionHandle())
        #expect(handle.connect(to: TestHost.target()) { _ in true } == .connected)
        defer { handle.disconnect() }
        let before = Self.pdusTheServerSaw().count

        #expect(handle.send(.displayUpdates(false)))
        #expect(waitForServer(toSee: "allow=0", after: before, while: handle))
        while handle.takeDirtyRect() != nil {}

        #expect(handle.send(.displayUpdates(true)))
        #expect(waitForServer(toSee: "allow=1", after: before, while: handle))

        // Resuming repaints the whole desktop.
        let width = handle.framebufferWidth
        let height = handle.framebufferHeight
        var covered: RDPFramebuffer.Rect?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            _ = handle.poll(timeoutMilliseconds: 100)
            while let rect = handle.takeDirtyRect() {
                covered = covered.map { $0.union(rect) } ?? rect
            }
            if let covered, covered.width >= width, covered.height >= height { break }
        }
        let rect = try #require(covered, "no picture after resuming")
        #expect(rect.x == 0 && rect.y == 0 && rect.width >= width && rect.height >= height)
    }
}
