import CryptoKit
import Foundation
import Security

extension RDPCertificate {
    /// Reads the certificate a server presented from PEM text: the server's
    /// own certificate first, then the rest of its chain. Returns nil when
    /// the text holds no certificate the system can read.
    public init?(host: String, port: UInt16, pemChain: String) {
        let chain = Self.derCertificates(inPEM: pemChain)
        guard let leaf = chain.first, let certificate = SecCertificateCreateWithData(nil, leaf as CFData) else {
            return nil
        }

        var commonName: CFString?
        _ = SecCertificateCopyCommonName(certificate, &commonName)
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        let details = Self.details(of: certificate)

        self.init(
            host: host,
            port: port,
            commonName: commonName as String? ?? subject,
            subject: subject,
            issuer: details.issuer ?? "",
            fingerprint: Self.fingerprint(ofDER: leaf),
            validFrom: details.validFrom,
            validUntil: details.validUntil,
            chain: chain
        )
    }

    /// SHA-256 as colon-separated lowercase hex pairs.
    public static func fingerprint(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The DER contents of every certificate block in PEM text, in order.
    static func derCertificates(inPEM text: String) -> [Data] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var certificates: [Data] = []
        var rest = Substring(text)
        while let start = rest.range(of: begin), let stop = rest[start.upperBound...].range(of: end) {
            let base64 = rest[start.upperBound..<stop.lowerBound]
            if let der = Data(base64Encoded: String(base64), options: .ignoreUnknownCharacters), !der.isEmpty {
                certificates.append(der)
            }
            rest = rest[stop.upperBound...]
        }
        return certificates
    }

    private struct Details {
        var issuer: String?
        var validFrom: Date?
        var validUntil: Date?
    }

    private static func details(of certificate: SecCertificate) -> Details {
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
        guard let values = SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [String: [String: Any]]
        else { return Details() }

        func value(_ key: CFString) -> Any? {
            values[key as String]?[kSecPropertyKeyValue as String]
        }
        func date(_ key: CFString) -> Date? {
            (value(key) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }

        // The issuer is a list of name parts; prefer its common name.
        let parts = value(kSecOIDX509V1IssuerName) as? [[String: Any]] ?? []
        func part(_ oid: CFString) -> String? {
            parts.first { $0[kSecPropertyKeyLabel as String] as? String == oid as String }?[
                kSecPropertyKeyValue as String
            ] as? String
        }
        let issuer = part(kSecOIDCommonName) ?? part(kSecOIDOrganizationName)
            ?? parts.compactMap { $0[kSecPropertyKeyValue as String] as? String }.first

        return Details(
            issuer: issuer,
            validFrom: date(kSecOIDX509V1ValidityNotBefore),
            validUntil: date(kSecOIDX509V1ValidityNotAfter)
        )
    }
}

/// Asks macOS whether a server certificate is trustworthy on its own: a valid
/// chain to a root the system trusts, issued for the host being connected to.
public enum RDPCertificateVerifier {
    /// `anchors` and `date` exist for tests: certificates to trust instead of
    /// the system's roots, in DER, and the moment to judge validity at.
    ///
    /// The evaluation may ask the network about revocation, so it must not
    /// run on the main thread.
    public static func isTrustedBySystem(
        _ certificate: RDPCertificate, anchors: [Data]? = nil, at date: Date? = nil
    ) -> Bool {
        let certificates = certificate.chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty, certificates.count == certificate.chain.count else { return false }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, certificate.host as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
            let trust
        else { return false }

        if let anchors {
            let roots = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard SecTrustSetAnchorCertificates(trust, roots as CFArray) == errSecSuccess,
                SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
            else { return false }
        }
        if let date, SecTrustSetVerifyDate(trust, date as CFDate) != errSecSuccess {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
