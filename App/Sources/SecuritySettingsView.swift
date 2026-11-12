import SwiftUI
import VistaraCore

/// Settings > Security: the certificates the user chose to always trust.
/// Removing one needs no confirmation, because the next connection to that
/// computer simply asks again.
struct SecuritySettingsView: View {
    let trustStore: CertificateTrustStore

    @State private var certificates: [TrustedCertificate] = []
    @State private var selection: TrustedCertificate.ID?
    @State private var removalFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trusted Certificates")
                .font(.headline)
            Text("Vistara connects to these computers without asking, as long as they present the same certificate.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(certificates, selection: $selection) {
                TableColumn("Computer") { certificate in
                    Text(certificate.port == 3389 ? certificate.host : certificate.id)
                }
                .width(min: 120, ideal: 180)
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
        .frame(minWidth: 560, minHeight: 320)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
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
