import AppKit
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// How a session window asks for, uses, and remembers credentials.
@Suite(.serialized)
@MainActor
struct CredentialsFlowTests {
    private static let nowhere = SessionTarget(
        name: "Nowhere", host: "127.0.0.1", port: 1, username: "nobody", domain: nil
    )

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
