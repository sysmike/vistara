import SwiftUI
import VistaraCore

/// Settings > Security: the certificates the user chose to always trust, for
/// computers and gateways. Removing one needs no confirmation, because the
/// next connection to that computer or gateway simply asks again.
struct SecuritySettingsView: View {
    let trustStore: CertificateTrustStore

    @State private var certificates: [TrustedCertificate] = []
    @State private var selection: TrustedCertificate.ID?
    @State private var removalFailed = false

    init(trustStore: CertificateTrustStore, selection: TrustedCertificate.ID? = nil) {
        self.trustStore = trustStore
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trusted Certificates")
                .font(.headline)
            Text(
                "Vistara connects to these computers and gateways without asking, as long as they present "
                    + "the same certificate."
            )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(certificates, selection: $selection) {
                TableColumn("Computer") { certificate in
                    HStack(spacing: 6) {
                        Text(Self.address(of: certificate))
                        if certificate.isGateway {
                            Text("Gateway")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(.secondary.opacity(0.5)))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.accessibilityLabel(of: certificate))
                }
                .width(min: 140, ideal: 200)
                TableColumn("SHA-256 Fingerprint") { certificate in
                    Text(certificate.fingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(certificate.fingerprint)
                }
                TableColumn("Trusted Since") { certificate in
                    Text(certificate.dateAdded.formatted(date: .abbreviated, time: .omitted))
                }
                .width(min: 90, ideal: 110)
            }
            .overlay {
                if certificates.isEmpty {
                    Text("No Trusted Certificates")
                        .foregroundStyle(.secondary)
                }
            }

            // The list shortens fingerprints; comparing needs all of one.
            Group {
                if let selected = certificates.first(where: { $0.id == selection }) {
                    Text(CertificateSheet.lines(ofFingerprint: selected.fingerprint))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("Select a certificate to see its whole fingerprint.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)

            HStack {
                if removalFailed {
                    Label("The certificate couldn’t be removed.", systemImage: "exclamationmark.triangle")
                }
                Spacer()
                Button("Remove", action: removeSelection)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    /// The host alone on the usual port: 3389 for a computer, 443 for a gateway.
    static func address(of certificate: TrustedCertificate) -> String {
        certificate.port == (certificate.isGateway ? 443 : 3389) ? certificate.host : certificate.id
    }

    static func accessibilityLabel(of certificate: TrustedCertificate) -> String {
        certificate.isGateway ? "\(address(of: certificate)), gateway" : address(of: certificate)
    }

    private func reload() {
        certificates = trustStore.certificates
        if let selection, !certificates.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func removeSelection() {
        guard let certificate = certificates.first(where: { $0.id == selection }) else { return }
        do {
            try trustStore.remove(host: certificate.host, port: certificate.port)
            removalFailed = false
        } catch {
            removalFailed = true
        }
        reload()
    }
}
