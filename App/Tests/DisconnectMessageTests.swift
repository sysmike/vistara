import RDPKit
import Testing
@testable import Vistara

@Suite
struct DisconnectMessageTests {
    @Test
    func aDisconnectTheUserAskedForOffersReconnect() {
        let message = DisconnectMessage(reason: .userRequested, name: "Build Server")
        #expect(message.title == "Disconnected from “Build Server”")
        #expect(message.action == "Reconnect")
        #expect(message.detail == nil)
    }

    @Test
    func aFailedConnectionNamesTheComputerAndKeepsTheCodeAsDetail() {
        let message = DisconnectMessage(reason: .connectionFailed(code: "FREERDP_ERROR_X"), name: "Build Server")
        #expect(message.title == "Can’t connect to “Build Server”")
        #expect(message.action == "Try Again")
        #expect(message.detail == "FREERDP_ERROR_X")
    }

    @Test
    func wrongCredentialsOfferNoRetryThatWouldFailAgain() {
        let message = DisconnectMessage(reason: .authenticationFailed, name: "Build Server")
        #expect(message.action == nil)
    }

    @Test(arguments: [
        RDPDisconnectReason.userRequested, .credentialsCancelled, .certificateRejected, .authenticationFailed,
        .connectionFailed(code: "CODE"), .connectionLost(code: "CODE")
    ])
    func everyMessageHasATitleAndNeverABareCode(reason: RDPDisconnectReason) {
        let message = DisconnectMessage(reason: reason, name: "Build Server")
        #expect(!message.title.isEmpty)
        #expect(!message.title.contains("CODE"))
        #expect(message.explanation?.contains("CODE") != true)
    }
}
