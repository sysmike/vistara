import AppKit
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

@Suite(.serialized)
@MainActor
struct SessionWindowTests {
    private static let nowhere = SessionTarget(
        name: "Nowhere", host: "127.0.0.1", port: 1, username: "nobody", domain: nil
    )

    /// A store with an account for `nowhere`, so connecting gets as far as
    /// the network without asking.
    private static func nobody() -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        try? store.save(StoredCredentials(username: "nobody", password: ""), for: nowhere.credentialKey, label: "Test")
        return store
    }

    @Test
    func windowUsesSystemChromeAndTheConnectionName() {
        let model = SessionModel(
            target: Self.nowhere, credentialStore: Self.nobody(), phase: .disconnected(.userRequested)
        )
        let controller = SessionWindowController(model: model)
        let window = controller.window

        #expect(window.title == "Nowhere")
        #expect(window.subtitle == "127.0.0.1")
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.toolbar == nil)
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        window.close()
    }

    @Test
    func connectingAppearsAtOnceAndAFailureIsShownInTheWindow() async {
        let model = SessionModel(target: Self.nowhere, credentialStore: Self.nobody())
        model.connect()
        #expect(model.phase == .connecting)
        #expect(model.isLive)

        await waitUntil("the session has ended") { !model.isLive }
        guard case .disconnected(.connectionFailed) = model.phase else {
            Issue.record("expected a failed connection, got \(model.phase)")
            return
        }
    }

    @Test
    func reconnectDoesNothingWhileASessionIsLive() async {
        let model = SessionModel(target: Self.nowhere, credentialStore: Self.nobody())
        model.connect()
        model.reconnect()
        #expect(model.phase == .connecting)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test(.enabled(if: TestServer.current != nil))
    func connectingCanBeCancelled() async throws {
        let server = try #require(TestServer.current)
        let model = SessionModel(target: server.address, credentialStore: try server.storeWithCredentials())
        model.connect()
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.userRequested))
        #expect(model.pendingCertificate == nil)
    }

    @Test(.enabled(if: TestServer.current != nil))
    func rejectingTheCertificateEndsTheConnection() async throws {
        let server = try #require(TestServer.current)
        let model = SessionModel(target: server.address, credentialStore: try server.storeWithCredentials())
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        #expect(model.pendingCertificate?.fingerprint.isEmpty == false)
        model.answerCertificate(trust: false)
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.certificateRejected))
    }

    @Test(.enabled(if: TestServer.current != nil))
    func aSessionDrawsInItsWindowAndClosingTheWindowDisconnects() async throws {
        let server = try #require(TestServer.current)
        let coordinator = SessionCoordinator(credentialStore: try server.storeWithCredentials())
        let controller = coordinator.open(server.address)
        let model = controller.model
        #expect(coordinator.liveSessionCount == 1)
        // A second request for the same computer reuses the window.
        #expect(coordinator.open(server.address) === controller)

        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }

        var desktop: RDPSessionView?
        await waitUntil("the desktop has been drawn") {
            desktop = controller.window.contentView?.firstDescendant(RDPSessionView.self)
            return (desktop?.drawCount ?? 0) > 0
        }
        let view = try #require(desktop)
        #expect(view.desktopFrame.width > 0)
        #expect(view.accessibilityLabel() == "Remote desktop, Test Server")
        // Typing goes to the desktop without a click first.
        #expect(controller.window.firstResponder === view)

        // Session > Disconnect closes the window, and that ends the session.
        #expect(controller.window.isVisible)
        coordinator.disconnect(model)
        #expect(!controller.window.isVisible)
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.userRequested))
        #expect(coordinator.liveSessionCount == 0)

        // Reconnect brings the session back in a model that has ended.
        model.reconnect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    // MARK: Credentials

    @Test
    func withNothingSavedTheSheetAsksAndCancelEndsTheConnection() async {
        let model = SessionModel(target: Self.nowhere, credentialStore: InMemoryCredentialStore())
        model.connect()
        await waitUntil("the credentials sheet is open") { model.pendingCredentials != nil }
        #expect(model.pendingCredentials == CredentialsRequest(username: "nobody", domain: "", remember: false))
        #expect(model.phase == .connecting)

        model.answerCredentials(nil)
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.credentialsCancelled))
        #expect(model.pendingCredentials == nil)
    }

    @Test
    func closingTheWindowWhileTheSheetIsOpenEndsTheSession() async {
        let model = SessionModel(target: Self.nowhere, credentialStore: InMemoryCredentialStore())
        model.connect()
        await waitUntil("the credentials sheet is open") { model.pendingCredentials != nil }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.pendingCredentials == nil)
    }

    @Test(.enabled(if: TestServer.current != nil))
    func aWrongPasswordReturnsToTheSheetAndTheRightOneIsRememberedOnRequest() async throws {
        let server = try #require(TestServer.current)
        let store = InMemoryCredentialStore()
        let model = SessionModel(target: server.address, credentialStore: store)
        model.connect()

        await waitUntil("the credentials sheet is open") { model.pendingCredentials != nil }
        #expect(model.pendingCredentials?.message == nil)
        let wrong = CredentialsAnswer(
            username: server.target.username, domain: "", password: "not the password", remember: true
        )
        model.answerCredentials(wrong)
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)

        // Refused: the sheet is back, says why, and nothing was saved.
        await waitUntil("the credentials sheet is back") { model.pendingCredentials?.message != nil }
        #expect(model.pendingCredentials?.message == "The user name or password is incorrect.")
        #expect(model.phase == .connecting)
        try #expect(store.credentials(for: server.address.credentialKey) == nil)

        let right = CredentialsAnswer(
            username: server.target.username, domain: "", password: server.password, remember: true
        )
        model.answerCredentials(right)
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }

        // Accepted and remembered, in the store and nowhere else.
        try #expect(store.credentials(for: server.address.credentialKey)?.password == server.password)
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        #expect(!"\(defaults)".contains(server.password))
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }

        // The next connection uses what is saved and does not ask.
        model.reconnect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        #expect(model.pendingCredentials == nil)
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test(.enabled(if: TestServer.current != nil))
    func withoutRememberNothingIsSavedAndAnOlderPasswordIsRemoved() async throws {
        let server = try #require(TestServer.current)
        let store = InMemoryCredentialStore()
        let stale = StoredCredentials(username: server.target.username, password: "an old password")
        try store.save(stale, for: server.address.credentialKey, label: "Test")
        let model = SessionModel(target: server.address, credentialStore: store)
        model.connect()

        // The saved password is tried first and refused.
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the credentials sheet is open") { model.pendingCredentials != nil }
        #expect(model.pendingCredentials?.username == server.target.username)
        #expect(model.pendingCredentials?.remember == true)

        let once = CredentialsAnswer(
            username: server.target.username, domain: "", password: server.password, remember: false
        )
        model.answerCredentials(once)
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }
        try #expect(store.credentials(for: server.address.credentialKey) == nil)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    /// The real Keychain, from inside the sandboxed app.
    @Test
    func theKeychainWorksInsideTheSandbox() throws {
        let store = KeychainCredentialStore(servicePrefix: "io.github.sysmike.vistara.tests.")
        let key = "app-" + UUID().uuidString
        defer { try? store.remove(for: key) }

        let credentials = StoredCredentials(username: "alice", domain: "CORP", password: "sandbox ✓")
        try store.save(credentials, for: key, label: "Vistara test")
        try #expect(store.credentials(for: key) == credentials)
        try store.remove(for: key)
        try #expect(store.credentials(for: key) == nil)
    }
}
