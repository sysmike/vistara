import Foundation
import Testing

@testable import RDPKit

/// In the serialized suite that also resizes the test server's screen, so
/// that the two never overlap.
extension IntegrationTests {
    /// A server may start a new activation the moment a connection turns
    /// active: the test server does, for a client whose desktop size differs
    /// from its screen. A Suppress Output that arrives in between makes
    /// FreeRDP's server drop the connection. It must wait until the server is
    /// done (#128).
    @Test(.enabled(if: TestHost.isTestServer, "Resizes the test server's screen and reads its log"))
    func aHiddenSessionSurvivesTheServerResizingItAsItConnects() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        var resized = (width: 0, height: 0)
        var hidden = (stayed: false, suppressed: false)
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            _ = MonitorIntegrationTests.waitForSize(session, 1024, 768)
            session.send([.desktopSize(width: 800, height: 600, scalePercent: 100)])
            resized = MonitorIntegrationTests.waitForSize(session, 800, 600)
            hidden = Self.connectHidden()
            // Restored, as other tests expect 1024 x 768.
            session.send([.desktopSize(width: 1024, height: 768, scalePercent: 100)])
            _ = MonitorIntegrationTests.waitForSize(session, 1024, 768)
            session.disconnect()
        }
        #expect(resized.width == 800 && resized.height == 600)
        #expect(hidden.stayed, "the server dropped the hidden session")
        #expect(hidden.suppressed, "the server never heard that the session is hidden")
    }

    /// Connects at 1024 x 768 to the smaller screen and, like a tab in the
    /// background, asks at once for no pictures. Whether the connection stayed
    /// up for a few seconds, and whether the server heard the request.
    private static func connectHidden() -> (stayed: Bool, suppressed: Bool) {
        guard let handle = SessionHandle() else { return (false, false) }
        let before = SuppressOutputIntegrationTests.pdusTheServerSaw().count
        guard handle.connect(to: TestHost.target(), decideCertificate: { _ in true }) == .connected else {
            return (false, false)
        }
        defer { handle.disconnect() }
        guard handle.send(.displayUpdates(false)) else { return (false, false) }
        var stayed = true
        let deadline = Date().addingTimeInterval(3)
        while stayed, Date() < deadline {
            stayed = handle.poll(timeoutMilliseconds: 100)
        }
        let suppressed = SuppressOutputIntegrationTests.pdusTheServerSaw().dropFirst(before).contains("allow=0")
        return (stayed, suppressed)
    }
}
