import AppKit
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// How a session window decides about certificates macOS does not trust.
@Suite(.serialized)
@MainActor
struct CertificateTrustFlowTests {
    @Test(.enabled(if: TestServer.current != nil))
    func alwaysTrustIsRememberedAndTheNextConnectionDoesNotAsk() async throws {
        let server = try #require(TestServer.current)
        let trustStore = temporaryTrustStore()
        let model = SessionModel(
            target: server.address, credentialStore: try server.storeWithCredentials(), trustStore: trustStore
        )
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        let certificate = try #require(model.pendingCertificate)
        #expect(certificate.previousFingerprint == nil)
        #expect(certificate.fingerprint.split(separator: ":").count == 32)
        #expect(certificate.validUntil != nil)
        #expect(trustStore.certificates.isEmpty)

        model.answerCertificate(.alwaysTrust)
        await waitUntil("the session is connected") { model.phase == .connected }
        #expect(trustStore.certificates.map(\.fingerprint) == [certificate.fingerprint])
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }

        // Trusted now: straight to the desktop, with no question on the way.
        var asked = false
        model.reconnect()
        await waitUntil("the session is connected") {
            asked = asked || model.pendingCertificate != nil
            return model.phase == .connected
        }
        #expect(!asked)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test(.enabled(if: TestServer.current != nil))
    func trustOnceIsNotRemembered() async throws {
        let server = try #require(TestServer.current)
        let trustStore = temporaryTrustStore()
        let model = SessionModel(
            target: server.address, credentialStore: try server.storeWithCredentials(), trustStore: trustStore
        )
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.trustOnce)
        await waitUntil("the session is connected") { model.phase == .connected }
        #expect(trustStore.certificates.isEmpty)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test(.enabled(if: TestServer.current != nil))
    func aChangedCertificateIsShownAsAChangeAndCancelKeepsWhatWasTrusted() async throws {
        let server = try #require(TestServer.current)
        let trustStore = temporaryTrustStore()
        let trusted = Array(repeating: "ab", count: 32).joined(separator: ":")
        try trustStore.add(host: server.address.host, port: server.address.port, fingerprint: trusted)
        let model = SessionModel(
            target: server.address, credentialStore: try server.storeWithCredentials(), trustStore: trustStore
        )
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        #expect(model.pendingCertificate?.previousFingerprint == trusted)
        #expect(model.pendingCertificate?.fingerprint != trusted)

        model.answerCertificate(.cancel)
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.certificateRejected))
        #expect(trustStore.certificates.map(\.fingerprint) == [trusted])
    }

    @Test
    func theChangedCertificateAlertCannotBeDismissedWithReturn() {
        var certificate = RDPCertificate(
            host: "build01.example.com", port: 3389, commonName: "build01", subject: "build01", issuer: "build01",
            fingerprint: Array(repeating: "cd", count: 32).joined(separator: ":")
        )
        certificate.previousFingerprint = Array(repeating: "ab", count: 32).joined(separator: ":")
        let alert = ChangedCertificateAlert.make(certificate: certificate, name: "Build Server")

        #expect(alert.alertStyle == .critical)
        #expect(alert.messageText == "The identity of “Build Server” has changed.")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Connect Anyway"])
        // No button answers to Return; Escape cancels.
        #expect(alert.buttons.allSatisfy { $0.keyEquivalent != "\r" })
        #expect(alert.buttons[0].keyEquivalent == "\u{1b}")
        #expect(alert.buttons[1].hasDestructiveAction)
        #expect(!alert.buttons[0].hasDestructiveAction)

        // Both fingerprints are there as selectable text.
        let text = alert.accessoryView as? NSTextField
        #expect(text?.isSelectable == true)
        #expect(text?.stringValue.contains("ab:ab:ab") == true)
        #expect(text?.stringValue.contains("cd:cd:cd") == true)
    }

    @Test
    func validityIsShownWithANoteWhenTodayIsOutside() {
        var certificate = RDPCertificate(
            host: "h", port: 1, commonName: "", subject: "", issuer: "", fingerprint: ""
        )
        #expect(CertificateSheet.validity(of: certificate) == nil)

        certificate.validFrom = Date(timeIntervalSince1970: 1_700_000_000)
        certificate.validUntil = Date(timeIntervalSince1970: 1_800_000_000)
        let during = CertificateSheet.validity(of: certificate, now: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(during?.contains(" to ") == true)
        #expect(during?.contains("(") == false)
        let after = CertificateSheet.validity(of: certificate, now: Date(timeIntervalSince1970: 1_850_000_000))
        #expect(after?.hasSuffix("(expired)") == true)
        let before = CertificateSheet.validity(of: certificate, now: Date(timeIntervalSince1970: 1_650_000_000))
        #expect(before?.hasSuffix("(not valid yet)") == true)
    }
}
