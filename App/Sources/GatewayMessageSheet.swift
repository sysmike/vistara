import RDPKit
import SwiftUI

/// What a gateway shows before connecting: a notice, or terms to accept
/// (docs/DESIGN.md, RD Gateway). Cancel does not connect. Terms have no
/// default button, so Return does not accept them unread; Escape cancels.
struct GatewayMessageSheet: View {
    let message: RDPGatewayMessage
    let gateway: String
    let name: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.headline(for: message, gateway: gateway, name: name))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 260)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Message from the gateway")

            HStack {
                Spacer()
                Button("Cancel") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                if message.requiresConsent {
                    Button("Accept") { answer(true) }
                } else {
                    Button("Continue") { answer(true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    static func headline(for message: RDPGatewayMessage, gateway: String, name: String) -> String {
        message.requiresConsent
            ? "The gateway “\(gateway)” asks you to accept these terms before connecting to “\(name)”."
            : "The gateway “\(gateway)” has a message for you before connecting to “\(name)”."
    }
}
