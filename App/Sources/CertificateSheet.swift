import RDPKit
import SwiftUI

/// Asks whether to continue with a certificate macOS does not trust on its
/// own, for a computer with no trusted certificate on record. Trusting takes
/// a deliberate click: Return and Escape both cancel.
struct CertificateSheet: View {
    let certificate: RDPCertificate
    let answer: (CertificateDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vistara can’t verify the identity of “\(certificate.host)”.")
                .font(.headline)
            Text(
                "Its certificate isn’t signed by an authority your Mac trusts. Compare the fingerprint with the "
                    + "one shown on that computer before you continue."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Issued to:", certificate.commonName.isEmpty ? certificate.subject : certificate.commonName)
                row("Issued by:", certificate.issuer)
                if let validity = Self.validity(of: certificate) {
                    row("Valid:", validity)
                }
            }
            .padding(.top, 4)

            fingerprint("SHA-256 fingerprint", certificate.fingerprint)

            HStack {
                Spacer()
                Button("Always Trust") { answer(.alwaysTrust) }
                Button("Trust Once") { answer(.trustOnce) }
                Button("Cancel") { answer(.cancel) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { answer(.cancel) }
    }

    /// "12 Nov 2026 to 14 Dec 2027", with a note when today is outside.
    static func validity(of certificate: RDPCertificate, now: Date = Date()) -> String? {
        guard let from = certificate.validFrom, let until = certificate.validUntil else { return nil }
        let range = "\(from.formatted(date: .abbreviated, time: .omitted)) to "
            + until.formatted(date: .abbreviated, time: .omitted)
        if now > until { return range + " (expired)" }
        if now < from { return range + " (not valid yet)" }
        return range
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fingerprint(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(Self.lines(ofFingerprint: value))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize()
        }
    }

    /// Breaks a colon-separated fingerprint into lines of 16 pairs, so a line
    /// never ends in the middle of a pair.
    static func lines(ofFingerprint fingerprint: String, pairsPerLine: Int = 16) -> String {
        let pairs = fingerprint.split(separator: ":")
        return stride(from: 0, to: pairs.count, by: pairsPerLine)
            .map { pairs[$0..<min($0 + pairsPerLine, pairs.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }
}
