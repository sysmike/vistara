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
                row("SHA-256 fingerprint:", certificate.fingerprint, monospaced: true)
                if let previous = certificate.previousFingerprint {
                    row("Seen before:", previous, monospaced: true)
                }
            }
            .padding(.vertical, 4)

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

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
