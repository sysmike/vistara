import Foundation
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// The test gateway from scripts/run-test-gateway.sh, as the app tests see it.
struct TestGateway {
    let gateway: Connection.Gateway
    let password: String

    static var current: TestGateway? {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["VISTARA_TEST_GATEWAY_HOST"], !host.isEmpty,
              let user = environment["VISTARA_TEST_GATEWAY_USER"],
              let password = environment["VISTARA_TEST_GATEWAY_PASSWORD"],
              TestServer.current != nil
        else { return nil }
        let port = environment["VISTARA_TEST_GATEWAY_PORT"].flatMap { Int($0) } ?? 443
        let gateway = Connection.Gateway(
            usage: .always, host: host, port: port, signIn: .anotherAccount, username: user
        )
        return TestGateway(gateway: gateway, password: password)
    }
}

/// Through the test gateway to the test server, from the gateway's sheet to
/// a connected session (#124).
@Suite(.serialized, .enabled(if: TestGateway.current != nil))
@MainActor
struct GatewayFlowTests {
    @Test(.timeLimit(.minutes(1)))
    func theGatewaysPasswordAndCertificateAreRememberedForTheGateway() async throws {
        let server = try #require(TestServer.current)
        let gateway = try #require(TestGateway.current)
        let store = InMemoryCredentialStore()
        let trustStore = temporaryTrustStore()
        var target = server.target
        target.gateway = gateway.gateway

        let model = SessionModel(target: target, credentialStore: store, trustStore: trustStore)
        model.connect()
        await waitUntil("the gateway's sheet is open") { model.gatewayQuestions.pendingCredentials != nil }
        #expect(model.gatewayQuestions.pendingCredentials?.username == gateway.gateway.username)
        let account = gateway.gateway.username
        model.answerGatewayCredentials(
            CredentialsAnswer(username: account, domain: "", password: gateway.password, remember: true)
        )
        await waitUntil("the computer's sheet is open") { model.pendingCredentials != nil }
        model.answerCredentials(
            CredentialsAnswer(username: server.target.username, domain: "", password: server.password, remember: false)
        )
        await waitUntil("the gateway's certificate is asked about") { model.pendingCertificate != nil }
        #expect(model.pendingCertificate?.isGateway == true)
        #expect(model.pendingCertificate?.host == gateway.gateway.host)
        model.answerCertificate(.alwaysTrust)
        await waitUntil("the computer's certificate is asked about") { model.pendingCertificate?.isGateway == false }
        model.answerCertificate(.trustOnce)
        await waitUntil("the session is connected") { model.phase == .connected }

        // Saved for the gateway and user name; the gateway trusted as a gateway.
        let key = gateway.gateway.credentialKey(account: gateway.gateway.username)
        #expect(try store.credentials(for: key)?.password == gateway.password)
        #expect(try store.credentials(for: target.credentialKey) == nil)
        let trusted = trustStore.certificates.first { $0.host == gateway.gateway.host.lowercased() }
        #expect(trusted?.isGateway == true)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }

        // Another connection through the gateway asks only for the computer.
        var other = target
        other.name = "Through the Same Gateway"
        let second = SessionModel(target: other, credentialStore: store, trustStore: trustStore)
        second.connect()
        await waitUntil("the computer's sheet is open") { second.pendingCredentials != nil }
        #expect(second.gatewayQuestions.pendingCredentials == nil)
        second.answerCredentials(
            CredentialsAnswer(username: server.target.username, domain: "", password: server.password, remember: false)
        )
        await waitUntil("the computer's certificate is asked about") { second.pendingCertificate != nil }
        #expect(second.pendingCertificate?.isGateway == false)
        second.answerCertificate(.trustOnce)
        await waitUntil("the session is connected") { second.phase == .connected }
        second.disconnect()
        await waitUntil("the session has ended") { !second.isLive }
    }
}
