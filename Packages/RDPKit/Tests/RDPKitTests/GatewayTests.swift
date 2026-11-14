import Foundation
import Testing

@testable import RDPKit

/// The gateway as RDPKit hands it to FreeRDP, and what its failures mean
/// (docs/DESIGN.md, RD Gateway; #122). No server is needed.
@Suite
struct GatewaySettingsTests {
    private static let account = RDPCredentials(username: "gateway-user", domain: "GATEWAY", password: "")

    /// Connects to closed ports, which fails at once, and reads back what
    /// FreeRDP was given.
    private func connect(
        through gateway: SessionHandle.Gateway?
    ) throws -> (settings: SessionHandle.GivenSettings, result: SessionHandle.ConnectResult) {
        let handle = try #require(SessionHandle())
        var target = SessionHandle.Target(host: "127.0.0.1", port: 1, username: "nobody", domain: nil, password: "")
        target.gateway = gateway
        let result = handle.connect(to: target)
        return (handle.settingsGiven, result)
    }

    @Test func withoutAGatewayTheConnectionIsDirect() throws {
        let given = try connect(through: nil).settings.gateway
        #expect(!given.enabled)
        #expect(given.usageMethod == 0)
    }

    @Test func aGatewayIsAlwaysUsedOverHTTPAndWebSocketOnly() throws {
        let given = try connect(through: .init(host: "127.0.0.1", port: 2)).settings.gateway
        #expect(given.enabled)
        #expect(given.usageMethod == 1)
        #expect(!given.bypassesLocalAddresses)
        #expect(given.httpTransport)
        #expect(given.webSockets)
        #expect(!given.rpcTransport)
        #expect(!given.udpTransport)
        #expect(given.port == 2)
    }

    @Test func theComputersAccountOrTheGatewaysOwn() throws {
        #expect(try connect(through: .init(host: "127.0.0.1", port: 2)).settings.gateway.usesSameCredentials)
        let own = SessionHandle.Gateway(host: "127.0.0.1", port: 2, credentials: Self.account)
        #expect(try !connect(through: own).settings.gateway.usesSameCredentials)
    }

    @Test func aGatewayThatDoesNotAnswerIsTheGatewaysFailure() throws {
        let result = try connect(through: .init(host: "127.0.0.1", port: 2)).result
        guard case .failed(let failure) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(failure.kind == .gatewayUnreachable, "\(failure.name)")
    }
}

@Suite
struct GatewayFailureTests {
    private static func connect(_ error: UInt32) -> UInt32 { 0x0002_0000 | error }

    /// What the gateway itself answered ([MS-TSGU] 2.2.6), whenever it comes.
    @Test func theGatewaysOwnAnswersAreTheGateways() {
        let answers: [(UInt32, RDPFailure.Kind)] = [
            (0x8007_59DA, .gatewayRefusedComputer),  // E_PROXY_RAP_ACCESSDENIED
            (0x0000_59FC, .gatewayRefusedComputer),  // E_PROXY_REAUTH_RAP_FAILED
            (0x8007_59F8, .gatewaySignInRefused),  // E_PROXY_COOKIE_AUTHENTICATION_ACCESS_DENIED
            (0x0000_59FA, .gatewaySignInRefused)  // E_PROXY_REAUTH_AUTHN_FAILED
        ]
        for (code, kind) in answers {
            for atGateway in [false, true] {
                #expect(RDPFailure.kind(code: code, osError: nil, whileConnected: false, atGateway: atGateway) == kind)
            }
        }
    }

    /// Before the connection gets past the gateway, failing to reach it or to
    /// sign in is the gateway's.
    @Test func reachingAndSigningInBeforeTheComputerAreTheGateways() {
        let atGateway: [(UInt32, Int32?, RDPFailure.Kind)] = [
            (Self.connect(0x05), nil, .gatewayUnreachable),  // DNS_NAME_NOT_FOUND
            (Self.connect(0x06), ECONNREFUSED, .gatewayUnreachable),  // CONNECT_FAILED
            (Self.connect(0x06), ETIMEDOUT, .gatewayUnreachable),
            (Self.connect(0x0D), nil, .gatewayUnreachable),  // CONNECT_TRANSPORT_FAILED
            (Self.connect(0x16), nil, .gatewaySignInRefused),  // CONNECT_ACCESS_DENIED
            (Self.connect(0x09), nil, .gatewaySignInRefused),  // AUTHENTICATION_FAILED
            (Self.connect(0x1D), nil, .starting)  // TARGET_BOOTING stays the computer's
        ]
        for (code, osError, kind) in atGateway {
            let classified = RDPFailure.kind(code: code, osError: osError, whileConnected: false, atGateway: true)
            #expect(classified == kind, "\(RDPFailure.freeRDPName(code: code))")
        }
    }

    /// Past the gateway, or once connected, nothing changes.
    @Test func pastTheGatewayFailuresAreTheComputers() {
        let denied = Self.connect(0x16)
        #expect(RDPFailure.kind(code: denied, osError: nil, whileConnected: false) == .accountRestricted)
        let transport = Self.connect(0x0D)
        #expect(RDPFailure.kind(code: transport, osError: nil, whileConnected: true, atGateway: true) == .networkLost)
    }
}
