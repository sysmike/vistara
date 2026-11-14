import AppKit
import RDPKit

/// The one alert in Vistara: a computer or gateway presents a different
/// certificate from the one the user chose to always trust for it.
///
/// No button is the default, so Return does nothing and the alert has to be
/// read. Escape cancels. Continuing is marked as destructive, and applies to
/// this connection only: the trusted certificate stays on record until it is
/// removed in Settings.
@MainActor
enum ChangedCertificateAlert {
    static let cancelResponse = NSApplication.ModalResponse.alertFirstButtonReturn
    static let connectResponse = NSApplication.ModalResponse.alertSecondButtonReturn

    static func make(certificate: RDPCertificate, name: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        let which = certificate.isGateway ? "gateway" : "computer"
        alert.messageText = certificate.isGateway
            ? "The identity of the gateway “\(certificate.host)” has changed."
            : "The identity of “\(name)” has changed."
        alert.informativeText =
            "This \(which) presents a different certificate from the one you trusted. It may have been "
            + "reinstalled, or someone may be intercepting the connection. If you expected the change, remove "
            + "the old certificate in Settings > Security and trust the new one."

        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let connect = alert.addButton(withTitle: "Connect Anyway")
        connect.keyEquivalent = ""
        connect.hasDestructiveAction = true

        alert.accessoryView = fingerprints(
            trusted: certificate.previousFingerprint ?? "", presented: certificate.fingerprint
        )
        return alert
    }

    /// Both fingerprints as text that can be selected and copied.
    private static func fingerprints(trusted: String, presented: String) -> NSView {
        let text = [
            "Trusted before:", CertificateSheet.lines(ofFingerprint: trusted), "",
            "Presented now:", CertificateSheet.lines(ofFingerprint: presented)
        ].joined(separator: "\n")
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.isSelectable = true
        field.setAccessibilityLabel("Trusted and presented fingerprints")
        field.frame.size = field.fittingSize
        return field
    }
}
