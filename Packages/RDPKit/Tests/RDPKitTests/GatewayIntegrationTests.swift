import Foundation
import Testing
import os

@testable import RDPKit

/// Through the rdpgw test gateway from scripts/run-test-gateway.sh, in front
/// of the test server (#122). The gateway knows one user, lets it reach the
/// test server and nothing else, and has a certificate the Mac does not trust.
@Suite(.serialized, .enabled(if: GatewayHost.isConfigured, "Needs the test gateway from scripts/run-test-gateway.sh"),
       .timeLimit(.minutes(1)))
struct GatewayIntegrationTests {
    /// The certificates a session was asked about, in order.
    private final class Certificates: Sendable {
        private let seen = OSAllocatedUnfairLock<[RDPCertificate]>(initialState: [])
        func add(_ certificate: RDPCertificate) { seen.withLock { $0.append(certificate) } }
        var all: [RDPCertificate] { seen.withLock { $0 } }
    }

    /// A session to `host` through the gateway, signing in to it with
    /// `gatewayPassword`. Certificates are recorded, and accepted unless they
    /// are the gateway's and `acceptGateway` is false.
    private func connect(
        to host: String = TestHost.configuration.host, port: UInt16 = TestHost.configuration.port,
        gatewayPassword: String = GatewayHost.password, acceptGateway: Bool = true
    ) async -> (states: [RDPSessionState], certificates: [RDPCertificate]) {
        var configuration = TestHost.configuration
        configuration.host = host
        configuration.port = port
        configuration.gateway = RDPGateway(
            host: GatewayHost.host, port: GatewayHost.port, signIn: .ownAccount(username: GatewayHost.user, domain: nil)
        )
        let certificates = Certificates()
        let delegate = RDPSessionDelegate(
            credentials: { _ in TestHost.credentials() },
            certificateDecision: { certificate in
                certificates.add(certificate)
                return !certificate.isGateway || acceptGateway
            },
            gatewayCredentials: { _ in RDPCredentials(username: GatewayHost.user, password: gatewayPassword) }
        )
        let session = RDPSession(configuration: configuration, delegate: delegate)
        let states = await runToEnd(session) { state, session in
            if case .connected = state { session.disconnect() }
        }
        return (states, certificates.all)
    }

    private static func failure(in states: [RDPSessionState]) -> RDPFailure? {
        guard case .disconnected(.connectionFailed(let failure)) = states.last else { return nil }
        return failure
    }

    @Test func aSessionThroughTheGatewayReachesTheComputer() async {
        let log = GatewayHost.logLineCount()
        let (states, certificates) = await connect()
        #expect(states.contains { $0.kind == "connected" }, "\(states)")
        let gateway = certificates.filter(\.isGateway)
        #expect(gateway.count == 1)
        #expect(gateway.first?.host == GatewayHost.host)
        #expect(gateway.first?.port == GatewayHost.port)
        #expect(certificates.contains { !$0.isGateway && $0.port == TestHost.configuration.port })
        let added = GatewayHost.logLines().dropFirst(log)
        #expect(added.contains { $0.contains("NTLM: User \(GatewayHost.user) authenticated") })
        let computer = "\(TestHost.configuration.host):\(TestHost.configuration.port)"
        #expect(added.contains { $0.contains("Establishing connection to RDP server: \(computer)") })
    }

    @Test func aRefusedGatewaySignInIsTheGateways() async {
        let (states, certificates) = await connect(gatewayPassword: "not-the-password")
        let failure = Self.failure(in: states)
        #expect(failure?.kind == .gatewaySignInRefused, "\(states)")
        // It never got as far as the computer.
        #expect(certificates.allSatisfy(\.isGateway))
    }

    @Test func aComputerTheGatewayDoesNotAllowIsRefusedByIt() async {
        let log = GatewayHost.logLineCount()
        let (states, _) = await connect(to: GatewayHost.refusedHost, port: 3389)
        let failure = Self.failure(in: states)
        #expect(failure?.kind == .gatewayRefusedComputer, "\(states)")
        let added = GatewayHost.logLines().dropFirst(log)
        #expect(added.contains { $0.contains("Not allowed to connect to \(GatewayHost.refusedHost):3389") })
    }

    @Test func aRejectedGatewayCertificateEndsTheConnection() async {
        let (states, certificates) = await connect(acceptGateway: false)
        #expect(states.last == .disconnected(.certificateRejected), "\(states)")
        #expect(certificates.count == 1)
        #expect(certificates.first?.isGateway == true)
    }
}

/// The test gateway, read from the environment scripts/run-test-gateway.sh prints.
enum GatewayHost {
    static let environment = TestHost.environment
    static let isConfigured = TestHost.isTestServer && environment["VISTARA_TEST_GATEWAY_HOST"] != nil
    static var host: String { environment["VISTARA_TEST_GATEWAY_HOST"] ?? "" }
    static var port: UInt16 { UInt16(environment["VISTARA_TEST_GATEWAY_PORT"] ?? "") ?? 443 }
    static var user: String { environment["VISTARA_TEST_GATEWAY_USER"] ?? "" }
    static var password: String { environment["VISTARA_TEST_GATEWAY_PASSWORD"] ?? "" }
    static var refusedHost: String { environment["VISTARA_TEST_GATEWAY_REFUSED_HOST"] ?? "" }

    /// The gateway's log, line by line.
    static func logLines() -> [String] {
        guard let path = environment["VISTARA_TEST_GATEWAY_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").map(String.init)
    }

    /// How many lines the log has, to read only what comes after.
    static func logLineCount() -> Int { logLines().count }
}
