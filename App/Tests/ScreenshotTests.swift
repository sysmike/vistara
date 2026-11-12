import AppKit
import RDPKit
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// Renders every state of the session window to a PNG. CI uploads the files
/// so each pull request can be looked at, not only compiled.
@Suite(.serialized)
@MainActor
struct ScreenshotTests {
    private static let target = SessionTarget(
        name: "Build Server", host: "build01.example.com", port: 3389, username: "alice", domain: nil
    )
    private static let windowSize = NSSize(width: 720, height: 450)

    private static let certificate = RDPCertificate(
        host: "build01.example.com",
        port: 3389,
        commonName: "build01.example.com",
        subject: "CN = build01.example.com",
        issuer: "CN = build01.example.com",
        fingerprint: "3f:9a:11:c4:5e:7b:02:d8:66:1a:90:ef:4c:33:b7:25:8d:e1:0f:72:a4:5b:c9:16:e8:30:7d:94:2b:6f:ac:51"
    )

    @Test
    func launcher() async throws {
        let size = NSSize(width: 380, height: 100)
        let bytes = try await Screenshots.write(LauncherView { _ in }, size: size, name: "launcher")
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func connecting(dark: Bool) async throws {
        let model = SessionModel(target: Self.target, credentialStore: InMemoryCredentialStore(), phase: .connecting)
        let name = dark ? "connecting-dark" : "connecting"
        let view = SessionContentView(model: model)
        let bytes = try await Screenshots.write(view, size: Self.windowSize, name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test
    func disconnected() async throws {
        let examples: [(name: String, reason: RDPDisconnectReason)] = [
            ("cancelled", .userRequested),
            ("failed", .connectionFailed(code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")),
            ("lost", .connectionLost(code: "ERRINFO_RPC_INITIATED_DISCONNECT")),
            ("wrong-password", .authenticationFailed),
            ("certificate-rejected", .certificateRejected)
        ]
        for example in examples {
            let model = SessionModel(
                target: Self.target, credentialStore: InMemoryCredentialStore(), phase: .disconnected(example.reason)
            )
            let view = SessionContentView(model: model)
            let bytes = try await Screenshots.write(view, size: Self.windowSize, name: example.name)
            #expect(bytes > 0)
        }
    }

    @Test(arguments: [false, true])
    func credentialsSheet(dark: Bool) async throws {
        let request = CredentialsRequest(username: "", domain: "", remember: false)
        let view = CredentialsSheet(name: "Build Server", request: request) { _ in }
        let size = NSSize(width: 420, height: 230)
        let name = dark ? "credentials-dark" : "credentials"
        let bytes = try await Screenshots.write(view, size: size, name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test
    func credentialsSheetAfterARefusal() async throws {
        let request = CredentialsRequest(
            username: "alice", domain: "CORP", remember: true, message: "The user name or password is incorrect."
        )
        let view = CredentialsSheet(name: "Build Server", request: request) { _ in }
        let size = NSSize(width: 420, height: 260)
        let bytes = try await Screenshots.write(view, size: size, name: "credentials-refused")
        #expect(bytes > 0)
    }

    @Test
    func changedCertificateSheet() async throws {
        var changed = Self.certificate
        changed.previousFingerprint =
            "a1:07:5c:de:42:90:3b:f8:19:c6:7e:05:d3:68:2a:b4:91:0c:e7:36:5f:a8:14:7b:c0:29:e5:83:4d:f1:6a:9e"
        let view = CertificateSheet(certificate: changed) { _ in }
        let size = NSSize(width: 520, height: 310)
        let bytes = try await Screenshots.write(view, size: size, name: "certificate-changed")
        #expect(bytes > 0)
    }

    @Test
    func fingerprintLinesNeverSplitAPair() {
        #expect(CertificateSheet.lines(ofFingerprint: "aa:bb:cc:dd:ee", pairsPerLine: 2) == "aa:bb\ncc:dd\nee")
        #expect(CertificateSheet.lines(ofFingerprint: Self.certificate.fingerprint).split(separator: "\n").count == 2)
        #expect(CertificateSheet.lines(ofFingerprint: "").isEmpty)
    }

    @Test(arguments: [false, true])
    func certificateSheet(dark: Bool) async throws {
        let name = dark ? "certificate-dark" : "certificate"
        let view = CertificateSheet(certificate: Self.certificate) { _ in }
        let bytes = try await Screenshots.write(view, size: NSSize(width: 520, height: 250), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
