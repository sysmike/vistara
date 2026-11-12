import AppKit
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
                        resizesDesktop: model.target.resolutionMode == .matchWindow,
                        usesHiDPI: model.target.usesHiDPI,
                        connectedScale: model.connectedScale,
                        input: { model.send($0) }
                    )
                        .id(ObjectIdentifier(framebuffer))
                }
            case .disconnected(let reason):
                DisconnectedView(
                    message: DisconnectMessage(reason: reason, name: model.target.name, host: model.target.host),
                    perform: { action in
                        switch action {
                        case .connect: model.reconnect()
                        case .useAnotherAccount: model.reconnectWithAnotherAccount()
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: credentialsArePresented) {
            if let request = model.pendingCredentials {
                CredentialsSheet(name: model.target.name, request: request) { answer in
                    model.answerCredentials(answer)
                }
            }
        }
        .sheet(isPresented: certificateIsPresented) {
            if let certificate = model.pendingCertificate {
                CertificateSheet(certificate: certificate) { decision in
                    model.answerCertificate(decision)
                }
            }
        }
    }

    private var credentialsArePresented: Binding<Bool> {
        Binding(
            get: { model.pendingCredentials != nil },
            set: { isPresented in
                if !isPresented { model.answerCredentials(nil) }
            }
        )
    }

    private var certificateIsPresented: Binding<Bool> {
        Binding(
            // A changed certificate is an alert on the window, not this sheet.
            get: { model.pendingCertificate.map { $0.previousFingerprint == nil } ?? false },
            set: { isPresented in
                if !isPresented, model.pendingCertificate?.previousFingerprint == nil {
                    model.answerCertificate(.cancel)
                }
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
    let perform: (DisconnectMessage.Action) -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 8) {
            Text(message.title)
                .font(.title2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let explanation = message.explanation {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = message.action {
                Button(action.title) { perform(action) }
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 12)
            }
            if let detail = message.detail {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(detail, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: 440)
        .padding(40)
    }
}

/// The remote desktop, scaled to fit, on black.
struct RemoteDesktopView: NSViewRepresentable {
    let framebuffer: RDPFramebuffer
    let name: String
    let translatesEditingShortcuts: Bool
    /// Whether the remote desktop follows the size of the window.
    let resizesDesktop: Bool
    let usesHiDPI: Bool
    let connectedScale: UInt16
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
        view.connectedScale = connectedScale
        view.usesHiDPI = usesHiDPI
        view.resizesDesktop = resizesDesktop
    }
}
