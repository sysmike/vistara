import AppKit
import RDPKit
import RDPKitUI
import SwiftUI

/// The content of a session window: exactly one state at a time.
struct SessionContentView: View {
    let model: SessionModel
    /// Settings > Keyboard.
    @AppStorage("TranslateEditingShortcuts") private var translatesEditingShortcuts = true
    @AppStorage(KeyboardSettingsView.rightCommandKey) private var rightCommandIsWindowsKey = false

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
                        rightCommandIsWindowsKey: rightCommandIsWindowsKey,
                        resizesDesktop: model.target.resolutionMode == .matchWindow,
                        usesHiDPI: model.target.usesHiDPI,
                        connectedScale: model.connectedScale,
                        input: { model.send($0) }
                    )
                        .id(ObjectIdentifier(framebuffer))
                }
            case .reconnecting(let reconnection):
                ReconnectingView(
                    name: model.target.name,
                    lastFrame: model.lastFrame,
                    isTrying: reconnection.isTrying,
                    cancel: { model.cancelReconnecting() },
                    reconnectNow: { model.reconnectNow() }
                )
            case .disconnected(let reason):
                DisconnectedView(
                    message: message(for: reason),
                    perform: { action in
                        switch action {
                        case .connect: model.reconnect()
                        case .useAnotherAccount: model.reconnectWithAnotherAccount()
                        case .editConnection: model.onEditConnection?()
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

    private func message(for reason: RDPDisconnectReason) -> DisconnectMessage {
        model.disconnectMessage(for: reason)
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
                .accessibilityLabel("Connecting")
            Text("Connecting to “\(name)”…")
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
    }
}

/// The last picture of the lost session, dimmed, with what is happening and
/// a way to stop it.
struct ReconnectingView: View {
    let name: String
    let lastFrame: CGImage?
    /// An attempt is running, rather than waiting for the next one.
    let isTrying: Bool
    let cancel: () -> Void
    let reconnectNow: () -> Void

    var body: some View {
        ZStack {
            if let lastFrame {
                Color.black
                Image(decorative: lastFrame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .opacity(0.4)
            }
            VStack(spacing: 12) {
                ProgressView()
                    .accessibilityLabel("Reconnecting")
                Text("Reconnecting to “\(name)”…")
                    .font(.title3)
                Text("The connection was lost. Your session keeps running on the computer.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Reconnect Now", action: reconnectNow)
                        .disabled(isTrying)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 360)
            .padding(24)
            .modifier(ReconnectingPanel())
        }
        .accessibilityElement(children: .contain)
    }
}

/// The controls float over the remote picture: on macOS 26 in one panel
/// of regular Liquid Glass, which keeps the text legible over any desktop
/// (HIG Materials), and in a material panel before.
private struct ReconnectingPanel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct DisconnectedView: View {
    let message: DisconnectMessage
    let perform: (DisconnectMessage.Action) -> Void

    @State private var showsDetails: Bool

    init(
        message: DisconnectMessage, showsDetails: Bool = false, perform: @escaping (DisconnectMessage.Action) -> Void
    ) {
        self.message = message
        self.perform = perform
        _showsDetails = State(initialValue: showsDetails)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(message.title)
                .font(.title2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let explanation = message.explanation {
                // What to do next: in the label color, which reads at more
                // than 4.5:1 in both appearances.
                Text(explanation)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = message.action {
                HStack {
                    if let secondary = message.secondaryAction {
                        Button(secondary.title) { perform(secondary) }
                    }
                    Button(action.title) { perform(action) }
                        .keyboardShortcut(.defaultAction)
                }
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
    let rightCommandIsWindowsKey: Bool
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
        view.rightCommandIsWindowsKey = rightCommandIsWindowsKey
        view.inputHandler = input
        view.connectedScale = connectedScale
        view.usesHiDPI = usesHiDPI
        view.resizesDesktop = resizesDesktop
    }
}
