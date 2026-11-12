import RDPKit
import RDPKitUI
import SwiftUI

/// The content of a session window: exactly one state at a time.
struct SessionContentView: View {
    let model: SessionModel
    /// The switch for this arrives with Settings > Keyboard (issue #30).
    @AppStorage("TranslateEditingShortcuts") private var translatesEditingShortcuts = true

    var body: some View {
        Group {
            switch model.phase {
            case .connecting:
                ConnectingView(name: model.target.name, cancel: { model.disconnect() })
            case .connected:
                if let framebuffer = model.framebuffer {
                    RemoteDesktopView(
                        framebuffer: framebuffer,
                        name: model.target.name,
                        translatesEditingShortcuts: translatesEditingShortcuts,
                        input: { model.send($0) }
                    )
                        .id(ObjectIdentifier(framebuffer))
                }
            case .disconnected(let reason):
                DisconnectedView(
                    message: DisconnectMessage(reason: reason, name: model.target.name),
                    reconnect: { model.reconnect() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: certificateIsPresented) {
            if let certificate = model.pendingCertificate {
                CertificateSheet(certificate: certificate) { trust in
                    model.answerCertificate(trust: trust)
                }
            }
        }
    }

    private var certificateIsPresented: Binding<Bool> {
        Binding(
            get: { model.pendingCertificate != nil },
            set: { isPresented in
                if !isPresented { model.answerCertificate(trust: false) }
            }
        )
    }
}

struct ConnectingView: View {
    let name: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Connecting to “\(name)”…")
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
    }
}

struct DisconnectedView: View {
    let message: DisconnectMessage
    let reconnect: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message.title)
                .font(.title2)
                .multilineTextAlignment(.center)
            if let explanation = message.explanation {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action = message.action {
                Button(action, action: reconnect)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 12)
            }
            if let detail = message.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: 420)
        .padding(40)
    }
}

/// The remote desktop, scaled to fit, on black.
struct RemoteDesktopView: NSViewRepresentable {
    let framebuffer: RDPFramebuffer
    let name: String
    let translatesEditingShortcuts: Bool
    let input: ([RDPInputEvent]) -> Void

    func makeNSView(context: Context) -> RDPSessionView {
        let view = RDPSessionView(framebuffer: framebuffer, connectionName: name)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RDPSessionView, context: Context) {
        view.connectionName = name
        view.translatesEditingShortcuts = translatesEditingShortcuts
        view.inputHandler = input
    }
}
