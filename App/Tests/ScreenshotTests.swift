import AppKit
import RDPKit
import SwiftUI
import Testing
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
    func launcher() throws {
        let size = NSSize(width: 380, height: 170)
        let bytes = try Screenshots.write(LauncherView { _, _ in }, size: size, name: "launcher")
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func connecting(dark: Bool) throws {
        let model = SessionModel(target: Self.target, password: "", phase: .connecting)
        let name = dark ? "connecting-dark" : "connecting"
        let view = SessionContentView(model: model)
        let bytes = try Screenshots.write(view, size: Self.windowSize, name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test
    func disconnected() throws {
        let examples: [(name: String, reason: RDPDisconnectReason)] = [
            ("disconnected", .userRequested),
            ("failed", .connectionFailed(code: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")),
            ("lost", .connectionLost(code: "ERRINFO_RPC_INITIATED_DISCONNECT")),
            ("wrong-password", .authenticationFailed),
            ("certificate-rejected", .certificateRejected)
        ]
        for example in examples {
            let model = SessionModel(target: Self.target, password: "", phase: .disconnected(example.reason))
            let view = SessionContentView(model: model)
            let bytes = try Screenshots.write(view, size: Self.windowSize, name: example.name)
            #expect(bytes > 0)
        }
    }

    @Test(arguments: [false, true])
    func certificateSheet(dark: Bool) throws {
        let name = dark ? "certificate-dark" : "certificate"
        let view = CertificateSheet(certificate: Self.certificate) { _ in }
        let bytes = try Screenshots.write(view, size: NSSize(width: 520, height: 230), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
