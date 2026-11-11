import Foundation
import Testing

@testable import RDPKit

/// Where the integration tests connect, read from the environment. The tests
/// are skipped unless `VISTARA_TEST_RDP_HOST` is set (see scripts/run-test-server.sh).
private enum TestHost {
    static let environment = ProcessInfo.processInfo.environment
    static let isConfigured = environment["VISTARA_TEST_RDP_HOST"] != nil

    static func target(password: String? = nil) -> SessionHandle.Target {
        SessionHandle.Target(
            host: environment["VISTARA_TEST_RDP_HOST"] ?? "",
            port: UInt16(environment["VISTARA_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: environment["VISTARA_TEST_RDP_USER"] ?? "",
            domain: environment["VISTARA_TEST_RDP_DOMAIN"],
            password: password ?? environment["VISTARA_TEST_RDP_PASSWORD"] ?? ""
        )
    }

    /// Asks the server for its certificate fingerprint by connecting without
    /// trusting anything, which must be refused.
    static func fingerprint() throws -> String {
        let session = try #require(SessionHandle())
        guard case .certificateUntrusted(let fingerprint?) = session.connect(to: target()) else {
            throw FingerprintUnavailable()
        }
        return fingerprint
    }

    struct FingerprintUnavailable: Error {}
}

@Suite(.serialized, .enabled(if: TestHost.isConfigured, "Set VISTARA_TEST_RDP_HOST to run"))
struct IntegrationTests {
    @Test func unknownCertificateIsRefusedAndItsFingerprintReported() throws {
        let session = try #require(SessionHandle())
        let result = session.connect(to: TestHost.target())

        guard case .certificateUntrusted(let fingerprint) = result else {
            Issue.record("expected the certificate to be refused, got \(result)")
            return
        }
        // SHA-256 as colon-separated hex pairs.
        #expect(fingerprint?.split(separator: ":").count == 32)
        #expect(session.copyFramebuffer() == nil)
    }

    @Test func wrongFingerprintIsRefused() throws {
        let presented = try TestHost.fingerprint()
        let session = try #require(SessionHandle())
        let wrong = Array(repeating: "00", count: 32).joined(separator: ":")
        let result = session.connect(to: TestHost.target(), trustedFingerprint: wrong)

        #expect(result == .certificateUntrusted(fingerprint: presented))
    }

    @Test func connectsWithNLAAndReceivesAFramebuffer() throws {
        let fingerprint = try TestHost.fingerprint()
        let session = try #require(SessionHandle())
        #expect(session.connect(to: TestHost.target(), trustedFingerprint: fingerprint) == .connected)

        // Give the server up to ten seconds to paint.
        let deadline = Date().addingTimeInterval(10)
        while session.paintCount == 0, Date() < deadline {
            guard session.poll(timeoutMilliseconds: 100) else { break }
        }

        // Let the rest of the first full-screen update arrive.
        for _ in 0..<10 where session.poll(timeoutMilliseconds: 50) {}

        #expect(session.framebufferWidth == 1024)
        #expect(session.framebufferHeight == 768)
        #expect(session.paintCount > 0)

        // The test server shows one solid colour: blue 0x99, green 0x66, red 0x33.
        let pixels = try #require(session.copyFramebuffer())
        #expect(pixels.count == 1024 * 768 * 4)
        #expect(Array(pixels.prefix(3)) == [0x99, 0x66, 0x33])
        #expect(Array(pixels.suffix(4).prefix(3)) == [0x99, 0x66, 0x33])

        session.disconnect()
        #expect(session.copyFramebuffer() == nil)
        #expect(!session.poll(timeoutMilliseconds: 10))
    }

    @Test func wrongPasswordIsAnAuthenticationFailure() throws {
        let fingerprint = try TestHost.fingerprint()
        let session = try #require(SessionHandle())
        let result = session.connect(to: TestHost.target(password: "not the password"), trustedFingerprint: fingerprint)

        #expect(result == .authenticationFailed)
    }
}
