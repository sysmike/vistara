import Foundation
import Testing

@testable import RDPKit

@Suite
struct RDPCertificateTests {
    /// 15 January 2027, inside every fixture's validity.
    private let validDay = Date(timeIntervalSince1970: 1_800_000_000)
    /// In 2030, after the server certificate has expired.
    private let afterExpiry = Date(timeIntervalSince1970: 1_900_000_000)

    private func server(host: String = "build01.example.com") throws -> RDPCertificate {
        let chain = CertificateFixtures.server + "\n" + CertificateFixtures.root
        return try #require(RDPCertificate(host: host, port: 3389, pemChain: chain))
    }

    private var rootDER: Data {
        RDPCertificate.derCertificates(inPEM: CertificateFixtures.root)[0]
    }

    @Test func detailsAreReadFromTheServersCertificate() throws {
        let certificate = try server()
        #expect(certificate.host == "build01.example.com")
        #expect(certificate.port == 3389)
        #expect(certificate.commonName == "build01.example.com")
        #expect(certificate.issuer == "Vistara Test Root")
        #expect(certificate.fingerprint == CertificateFixtures.serverFingerprint)
        #expect(certificate.chain.count == 2)
        #expect(certificate.previousFingerprint == nil)

        // 12 November 2026 to 14 December 2027.
        let from = try #require(certificate.validFrom)
        let until = try #require(certificate.validUntil)
        #expect(from < validDay && validDay < until)
        #expect(abs(until.timeIntervalSince(from) - 397 * 86_400) < 1)
    }

    @Test func aSelfSignedCertificateNamesItselfAsIssuer() throws {
        let certificate = try #require(
            RDPCertificate(host: "10.0.0.5", port: 3390, pemChain: CertificateFixtures.selfSigned)
        )
        #expect(certificate.commonName == "WIN-SELFSIGNED")
        #expect(certificate.issuer == "WIN-SELFSIGNED")
        #expect(certificate.fingerprint == CertificateFixtures.selfSignedFingerprint)
        #expect(certificate.chain.count == 1)
    }

    @Test func textWithoutACertificateGivesNothing() {
        #expect(RDPCertificate(host: "h", port: 1, pemChain: "") == nil)
        #expect(RDPCertificate(host: "h", port: 1, pemChain: "not a certificate") == nil)
        let broken = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
        #expect(RDPCertificate(host: "h", port: 1, pemChain: broken) == nil)
    }

    @Test func fingerprintIsLowercaseHexPairs() {
        #expect(RDPCertificate.fingerprint(ofDER: Data()).hasPrefix("e3:b0:c4:42"))
        #expect(RDPCertificate.fingerprint(ofDER: Data()).split(separator: ":").count == 32)
    }

    // MARK: System trust

    @Test func aChainToATrustedRootForTheRightNameIsTrusted() throws {
        let certificate = try server()
        #expect(RDPCertificateVerifier.isTrustedBySystem(certificate, anchors: [rootDER], at: validDay))
    }

    @Test func theSameChainForAnotherNameIsNot() throws {
        let certificate = try server(host: "other.example.com")
        #expect(!RDPCertificateVerifier.isTrustedBySystem(certificate, anchors: [rootDER], at: validDay))
    }

    @Test func anExpiredCertificateIsNot() throws {
        let certificate = try server()
        #expect(!RDPCertificateVerifier.isTrustedBySystem(certificate, anchors: [rootDER], at: afterExpiry))
    }

    @Test func aRootTheSystemDoesNotKnowIsNotTrusted() throws {
        // No anchors given: the Mac's own roots decide, and they do not
        // include the test root.
        let certificate = try server()
        #expect(!RDPCertificateVerifier.isTrustedBySystem(certificate, at: validDay))
    }

    @Test func aSelfSignedCertificateIsNotTrusted() throws {
        let certificate = try #require(
            RDPCertificate(host: "WIN-SELFSIGNED", port: 3389, pemChain: CertificateFixtures.selfSigned)
        )
        #expect(!RDPCertificateVerifier.isTrustedBySystem(certificate, at: validDay))
    }

    @Test func aCertificateWithoutAChainIsNotTrusted() {
        let empty = RDPCertificate(host: "h", port: 1, commonName: "", subject: "", issuer: "", fingerprint: "")
        #expect(!RDPCertificateVerifier.isTrustedBySystem(empty))
    }
}
