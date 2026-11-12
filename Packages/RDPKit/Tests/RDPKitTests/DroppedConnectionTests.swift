import Foundation
import Testing

@testable import RDPKit

/// The test server cuts a client's connection without a word when it presses
/// F24, as a network that goes away would.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(1)))
struct DroppedConnectionTests {
    static let dropKey = RDPInputEvent.key(RDPScancode(0x76), isDown: true)

    @Test func aConnectionThatDropsIsANetworkLoss() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        let states = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            session.send([Self.dropKey])
        }
        guard case .disconnected(.connectionLost(let failure)) = states.last else {
            Issue.record("Expected a lost connection, got \(String(describing: states.last))")
            return
        }
        #expect(failure.kind == .networkLost)
    }
}
