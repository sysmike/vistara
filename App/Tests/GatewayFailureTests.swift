import AppKit
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// What the window says when the gateway is what failed, and what it offers
/// (docs/DESIGN.md, RD Gateway and Errors; #125).
@Suite(.serialized)
@MainActor
struct GatewayFailureTests {
    private static let gateway = "gateway.example.com"

    private func message(
        _ kind: RDPFailure.Kind, ownAccount: Bool = true, canEdit: Bool = false, gateway: String? = gateway
    ) -> DisconnectMessage {
        DisconnectMessage(
            reason: .connectionFailed(RDPFailure(kind: kind)), name: "Build Server", host: "build01",
            gateway: gateway, gatewayHasOwnAccount: ownAccount, canEditConnection: canEdit
        )
    }

    @Test
    func aGatewayThatCannotBeReachedIsNamed() {
        let message = message(.gatewayUnreachable, canEdit: true)
        #expect(message.title == "Can’t reach the gateway “gateway.example.com”")
        #expect(message.explanation == "Check the gateway’s address, and your network and VPN connection.")
        #expect(message.action == .connect("Try Again"))
        #expect(message.secondaryAction == .editConnection)
    }

    @Test
    func aRefusedGatewaySignInOffersAnotherAccountForTheGateway() {
        let own = message(.gatewaySignInRefused, canEdit: true)
        #expect(own.title == "The gateway “gateway.example.com” didn’t accept the user name or password")
        #expect(own.explanation == "Sign in with the account the gateway knows you by.")
        #expect(own.action == .useAnotherGatewayAccount)
        #expect(own.action?.title == "Use Another Account")
        #expect(own.secondaryAction == nil)

        // Signing in as the computer's account: another one is the computer's.
        let same = message(.gatewaySignInRefused, ownAccount: false)
        #expect(same.action == .useAnotherAccount)
        #expect(same.explanation?.contains("the computer’s account") == true)
    }

    @Test
    func aComputerTheGatewayDoesNotAllowSaysWhoToAsk() {
        let message = message(.gatewayRefusedComputer, canEdit: true)
        #expect(message.title == "The gateway “gateway.example.com” doesn’t allow a connection to “Build Server”")
        #expect(message.explanation?.contains("Ask whoever runs the gateway") == true)
        #expect(message.action == .connect("Try Again"))
        #expect(message.secondaryAction == .editConnection)
    }

    @Test
    func withoutItsAddressTheGatewayIsStillNamedAsOne() {
        #expect(message(.gatewayUnreachable, gateway: nil).title == "Can’t reach the gateway")
        #expect(message(.gatewayRefusedComputer, gateway: nil).title.hasPrefix("The gateway doesn’t allow"))
    }

    @Test
    func theWindowAndVoiceOverUseTheSameWords() {
        var target = SessionTarget(name: "Build Server", host: "build01", port: 3389)
        target.gateway = Connection.Gateway(usage: .always, host: Self.gateway, signIn: .anotherAccount)
        let reason = RDPDisconnectReason.connectionFailed(RDPFailure(kind: .gatewaySignInRefused))
        let store = InMemoryCredentialStore()
        let model = SessionModel(target: target, credentialStore: store, phase: .disconnected(reason))
        let shown = model.disconnectMessage(for: reason)
        #expect(shown.action == .useAnotherGatewayAccount)
        #expect(shown.title.contains("“gateway.example.com”"))
        #expect(SessionAnnouncement.text(for: model.phase, name: "Build Server", message: shown) == shown.title)
    }

    /// Reconnecting goes on while the gateway cannot be reached, and ends when
    /// it refuses the sign-in or the computer, as a computer's refusal does.
    @Test
    func reconnectingTriesAGatewayThatCannotBeReachedAgain() {
        func failed(_ kind: RDPFailure.Kind) -> RDPDisconnectReason { .connectionFailed(RDPFailure(kind: kind)) }
        #expect(ReconnectionPolicy.retries(after: failed(.gatewayUnreachable)))
        #expect(!ReconnectionPolicy.retries(after: failed(.gatewaySignInRefused)))
        #expect(!ReconnectionPolicy.retries(after: failed(.gatewayRefusedComputer)))
    }

    /// Use Another Account asks for the gateway's account even with one saved.
    @Test
    func useAnotherAccountAsksForTheGatewaysAccountAgain() async throws {
        let gateway = Connection.Gateway(usage: .always, host: Self.gateway, signIn: .anotherAccount, username: "kim")
        var target = SessionTarget(name: "Build Server", host: "127.0.0.1", port: 1)
        target.gateway = gateway
        let store = InMemoryCredentialStore()
        try store.save(StoredCredentials(username: "kim", password: "old"), for: gateway.credentialKey(account: "kim"),
                       label: "test")
        let refused = RDPDisconnectReason.connectionFailed(RDPFailure(kind: .gatewaySignInRefused))
        let model = SessionModel(target: target, credentialStore: store, phase: .disconnected(refused))

        model.reconnectWithAnotherGatewayAccount()
        await waitUntil("the gateway's sheet is open") { model.gatewayQuestions.pendingCredentials != nil }
        #expect(model.gatewayQuestions.pendingCredentials?.username == "kim")
        #expect(model.gatewayQuestions.pendingCredentials?.remember == true)
        model.answerGatewayCredentials(nil)
        await waitUntil("the session has ended") { !model.isLive }
    }

    // MARK: Screenshots

    @Test(arguments: [
        (RDPFailure.Kind.gatewayUnreachable, "gateway-unreachable"),
        (.gatewaySignInRefused, "gateway-sign-in-refused"),
        (.gatewayRefusedComputer, "gateway-refused-computer")
    ])
    func screenshot(kind: RDPFailure.Kind, name: String) async throws {
        let view = DisconnectedView(message: message(kind, canEdit: true)) { _ in }
        let bytes = try await Screenshots.write(view, size: NSSize(width: 720, height: 450), name: name)
        #expect(bytes > 0)
    }
}
