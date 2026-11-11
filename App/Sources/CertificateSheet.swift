import RDPKit
import SwiftUI

/// Asks whether to continue with a certificate that could not be verified.
/// Trusting takes a deliberate click: Return and Escape both cancel.
/// Remembering a certificate arrives with the trust store (issue #14).
struct CertificateSheet: View {
    let certificate: RDPCertificate
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vistara can’t verify the identity of “\(certificate.host)”.")
                .font(.headline)
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Issued to:", certificate.commonName.isEmpty ? certificate.subject : certificate.commonName)
                row("Issued by:", certificate.issuer)
            }
            .padding(.top, 4)

            fingerprint("SHA-256 fingerprint", certificate.fingerprint)
            if let previous = certificate.previousFingerprint {
                fingerprint("Fingerprint seen before", previous)
            }

            HStack {
                Spacer()
                Button("Trust Once") { answer(true) }
                Button("Cancel") { answer(false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { answer(false) }
    }

    private var explanation: String {
        if certificate.previousFingerprint == nil {
            "Its certificate isn’t signed by an authority your Mac trusts. Compare the fingerprint with the "
                + "one shown on that computer before you continue."
        } else {
            "This computer presented a different certificate before. It may have been reinstalled, or "
                + "someone may be intercepting the connection."
        }
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
