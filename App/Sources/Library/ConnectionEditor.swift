import SwiftUI
import VistaraCore

/// Creates or edits one connection. A sheet on the Connections window,
/// grouped like a System Settings form. No password field: the password is
/// asked for when connecting (docs/DESIGN.md).
struct ConnectionEditor: View {
    let folders: [Folder]
    let save: (Connection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionDraft
    /// Problems show once a field has been edited, or after trying to save.
    @State private var showsProblems: Bool

    init(
        draft: ConnectionDraft, folders: [Folder], showsProblems: Bool? = nil,
        save: @escaping (Connection) -> Void
    ) {
        self.folders = folders
        self.save = save
        _draft = State(initialValue: draft)
        _showsProblems = State(initialValue: showsProblems ?? !draft.isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                general
                display
                devices
                security
            }
            .formStyle(.grouped)
            .onChange(of: draft) { showsProblems = true }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 8)
        }
        .frame(width: 480)
        .frame(minHeight: 520, idealHeight: 640)
    }

    private var general: some View {
        Section("General") {
            let namePrompt = draft.trimmedHost.isEmpty ? "Optional" : draft.trimmedHost
            TextField("Name", text: $draft.name, prompt: Text(namePrompt))
            LabeledContent("Computer") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("Computer", text: $draft.host, prompt: Text("server.example.com"))
                        .labelsHidden()
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("Port", text: $draft.port)
                        .labelsHidden()
                        .frame(width: 60)
                        .accessibilityLabel("Port")
                }
            }
            problem(draft.hostProblem ?? draft.portProblem)
            TextField("User", text: $draft.username, prompt: Text("Optional"))
            TextField("Domain", text: $draft.domain, prompt: Text("Optional"))
            Picker("Folder", selection: $draft.folderID) {
                Text("None").tag(UUID?.none)
                if !folders.isEmpty { Divider() }
                ForEach(folders) { folder in
                    Text(folder.name).tag(UUID?.some(folder.id))
                }
            }
        }
    }

    private var display: some View {
        Section("Display") {
            Picker("Resolution", selection: $draft.resolutionMode) {
                Text("Match Window").tag(Connection.ResolutionMode.matchWindow)
                Text("Keep Size, Scale to Fit").tag(Connection.ResolutionMode.scaleToFit)
                Text("Fixed Size").tag(Connection.ResolutionMode.fixed)
            }
            if draft.resolutionMode == .fixed {
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        TextField("Width", text: $draft.fixedWidth)
                            .labelsHidden()
                            .frame(width: 64)
                            .accessibilityLabel("Width")
                        Text("×")
                            .foregroundStyle(.secondary)
                        TextField("Height", text: $draft.fixedHeight)
                            .labelsHidden()
                            .frame(width: 64)
                            .accessibilityLabel("Height")
                    }
                }
                problem(draft.sizeProblem)
            }
            Toggle("Optimize for Retina displays", isOn: $draft.usesHiDPI)
        }
    }

    private var devices: some View {
        Section("Devices and Audio") {
            Toggle("Share clipboard", isOn: $draft.sharesClipboard)
            Picker("Sound", selection: $draft.audioMode) {
                Text("Play on This Mac").tag(Connection.AudioMode.playOnThisMac)
                Text("Play on Remote Computer").tag(Connection.AudioMode.playOnRemote)
                Text("Off").tag(Connection.AudioMode.off)
            }
        }
    }

    private var security: some View {
        Section("Security") {
            Toggle("Reconnect if the connection drops", isOn: $draft.reconnectsAutomatically)
            Toggle("Require Network Level Authentication", isOn: $draft.requiresNLA)
            if let warning = draft.nlaWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Certificate", selection: $draft.certificatePolicy) {
                Text("Ask on First Use").tag(Connection.CertificatePolicy.askOnFirstUse)
                Text("Require a Trusted Certificate").tag(Connection.CertificatePolicy.requireTrusted)
            }
        }
    }

    /// A problem, under the field it belongs to, once it is worth showing.
    @ViewBuilder
    private func problem(_ message: String?) -> some View {
        if showsProblems, let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        showsProblems = true
        guard let connection = draft.connection() else { return }
        save(connection)
        dismiss()
    }
}
