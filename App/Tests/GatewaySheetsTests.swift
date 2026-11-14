import AppKit
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// What a session window asks for and remembers about a gateway, apart from
/// the computer (docs/DESIGN.md, RD Gateway; #124).
@Suite(.serialized)
@MainActor
struct GatewaySheetsTests {
    static let gateway = Connection.Gateway(
        usage: .always, host: "gateway.example.com", signIn: .anotherAccount, username: "kim"
    )

    /// A target behind the gateway, at a port where nothing answers.
    private static func target(name: String = "Build Server", gateway: Connection.Gateway = gateway) -> SessionTarget {
        var target = SessionTarget(name: name, host: "127.0.0.1", port: 1, username: "alice", domain: nil)
        target.gateway = gateway
        return target
    }

    static let certificate = RDPCertificate(
        host: "gateway.example.com", port: 443, commonName: "gateway.example.com",
        subject: "CN = gateway.example.com", issuer: "CN = Example Gateway CA",
        fingerprint: "9c:41:0e:d2:77:3a:b8:15:c0:6f:e4:29:5d:a3:81:7b:12:f6:4e:c9:30:8a:d5:67:b1:2c:f0:9e:43:d8:6a:15",
        validFrom: Date(timeIntervalSince1970: 1_790_000_000), validUntil: Date(timeIntervalSince1970: 1_990_000_000)
    )

    // MARK: Words

    @Test
    func theSheetsNameTheGatewayAndTheConnection() {
        #expect(CredentialsSheet.headline(name: "Build Server", gateway: nil)
            == "Enter your user name and password for “Build Server”.")
        #expect(CredentialsSheet.headline(name: "Build Server", gateway: "gw")
            == "Enter your user name and password for the gateway “gw”, to connect to “Build Server”.")
        var certificate = Self.certificate
        certificate.isGateway = true
        #expect(CertificateSheet.headline(for: certificate).contains("the gateway “gateway.example.com”"))
        #expect(CertificateSheet.explanation(for: certificate).contains("whoever runs the gateway"))
        certificate.isGateway = false
        #expect(!CertificateSheet.headline(for: certificate).contains("gateway “"))
        let consent = RDPGatewayMessage(kind: .consent, text: "Terms", mustBeShown: true, requiresConsent: true)
        #expect(GatewayMessageSheet.headline(for: consent, gateway: "gw", name: "Build Server").contains("accept"))
    }

    @Test
    func aChangedGatewayCertificateNamesTheGateway() {
        var certificate = Self.certificate
        certificate.isGateway = true
        certificate.previousFingerprint = "aa:bb"
        let alert = ChangedCertificateAlert.make(certificate: certificate, name: "Build Server")
        defer { alert.window.close() }
        #expect(alert.messageText == "The identity of the gateway “gateway.example.com” has changed.")
        #expect(alert.informativeText.hasPrefix("This gateway presents"))
    }

    @Test
    func settingsMarkGateways() {
        let gateway = TrustedCertificate(host: "gw", port: 443, fingerprint: "aa", dateAdded: Date(), isGateway: true)
        let computer = TrustedCertificate(host: "pc", port: 3389, fingerprint: "bb", dateAdded: Date())
        #expect(SecuritySettingsView.address(of: gateway) == "gw")
        #expect(SecuritySettingsView.accessibilityLabel(of: gateway) == "gw, gateway")
        #expect(SecuritySettingsView.accessibilityLabel(of: computer) == "pc")
    }

    // MARK: Questions

    @Test
    func theGatewayIsAskedForFirstAndCancellingEndsTheConnection() async {
        let model = SessionModel(target: Self.target(), credentialStore: InMemoryCredentialStore())
        model.connect()
        await waitUntil("the gateway's sheet is open") { model.gatewayQuestions.pendingCredentials != nil }
        let request = model.gatewayQuestions.pendingCredentials
        #expect(request == CredentialsRequest(username: "kim", domain: "", remember: false))
        #expect(model.pendingCredentials == nil)

        model.answerGatewayCredentials(nil)
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.credentialsCancelled))
        #expect(model.gatewayQuestions.pendingCredentials == nil)
    }

    /// A saved gateway password belongs to the gateway and user name, so any
    /// connection through the gateway uses it and asks only for the computer.
    @Test
    func aSavedGatewayPasswordIsSharedByConnectionsThroughTheGateway() async throws {
        let store = InMemoryCredentialStore()
        let saved = StoredCredentials(username: "kim", password: "gateway secret")
        try store.save(saved, for: Self.gateway.credentialKey(account: "kim"), label: "test")
        #expect(Self.gateway.credentialKey(account: "kim") == "gateway/gateway.example.com:443/kim")

        for name in ["Build Server", "File Server"] {
            let model = SessionModel(target: Self.target(name: name), credentialStore: store)
            model.connect()
            await waitUntil("the computer's sheet is open") { model.pendingCredentials != nil }
            #expect(model.gatewayQuestions.pendingCredentials == nil)
            model.answerCredentials(nil)
            await waitUntil("the session has ended") { !model.isLive }
        }

        // Without a gateway user, the one account saved for the gateway.
        var anonymous = Self.gateway
        anonymous.username = ""
        let model = SessionModel(target: Self.target(gateway: anonymous), credentialStore: store)
        model.connect()
        await waitUntil("the computer's sheet is open") { model.pendingCredentials != nil }
        #expect(model.gatewayQuestions.pendingCredentials == nil)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test
    func sameAsTheComputerAsksOnce() async {
        var gateway = Self.gateway
        gateway.signIn = .sameAsComputer
        let model = SessionModel(target: Self.target(gateway: gateway), credentialStore: InMemoryCredentialStore())
        model.connect()
        await waitUntil("the computer's sheet is open") { model.pendingCredentials != nil }
        #expect(model.gatewayQuestions.pendingCredentials == nil)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    // MARK: Keychain items

    @Test
    func aGatewaysPasswordsStayWhileAConnectionUsesIt() async throws {
        var library = Library()
        var connection = Connection(name: "Build Server", host: "build01")
        connection.gateway = Self.gateway
        library.connections = [connection]
        let (model, _) = try await temporaryLibrary(library)
        let store = InMemoryCredentialStore()
        let used = Self.gateway.credentialKey(account: "CORP\\kim")
        var other = Self.gateway
        other.host = "old-gateway.example.com"
        let unused = other.credentialKey(account: "kim")
        for key in [used, unused, connection.id.uuidString] {
            try store.save(StoredCredentials(username: "kim", password: "p"), for: key, label: "test")
        }

        model.removeOrphanedCredentials(from: store)
        #expect(try Set(store.keys()) == [used, connection.id.uuidString])

        // A gateway set to Never no longer keeps its passwords.
        connection.gateway.usage = .never
        await model.save(connection)
        model.removeOrphanedCredentials(from: store)
        #expect(try store.keys() == [connection.id.uuidString])
    }

    // MARK: Screenshots

    @Test(arguments: [false, true])
    func gatewayCredentialsSheet(dark: Bool) async throws {
        let request = CredentialsRequest(username: "kim", domain: "CORP", remember: false)
        let view = CredentialsSheet(name: "Build Server", gateway: "gateway.example.com", request: request) { _ in }
        let name = dark ? "gateway-credentials-dark" : "gateway-credentials"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 420, height: 250), name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func gatewayCertificateSheet(dark: Bool) async throws {
        var certificate = Self.certificate
        certificate.isGateway = true
        let view = CertificateSheet(certificate: certificate) { _ in }
        let name = dark ? "gateway-certificate-dark" : "gateway-certificate"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 520, height: 280), name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func gatewayConsentSheet(dark: Bool) async throws {
        let message = RDPGatewayMessage(
            kind: .consent,
            text: "This system is for authorized use by Example Corp employees only. Activity may be monitored "
                + "and recorded. By continuing you agree to the acceptable use policy.",
            mustBeShown: true, requiresConsent: true
        )
        let view = GatewayMessageSheet(
            message: message, gateway: "gateway.example.com", name: "Build Server"
        ) { _ in }
        let name = dark ? "gateway-consent-dark" : "gateway-consent"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 240), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
