import SwiftUI
import UniformTypeIdentifiers
import VistaraCore

/// Creates or edits one connection. A sheet on the Connections window,
/// grouped like a System Settings form. No password field: the password is
/// asked for when connecting (docs/DESIGN.md).
struct ConnectionEditor: View {
    let folders: [Folder]
    /// Tags in use elsewhere, offered as completions.
    var knownTags: [String] = []
    let save: (Connection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionDraft
    /// Problems show once a field has been edited, or after trying to save.
    @State private var showsProblems: Bool
    @State private var isChoosingFolders = false

    init(
        draft: ConnectionDraft, folders: [Folder], knownTags: [String] = [], showsProblems: Bool? = nil,
        save: @escaping (Connection) -> Void
    ) {
        self.folders = folders
        self.knownTags = knownTags
        self.save = save
        _draft = State(initialValue: draft)
        _showsProblems = State(initialValue: showsProblems ?? !draft.isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                general
                gateway
                display
                devices
                sharedFolders
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
            LabeledContent("Tags") {
                TagField(tags: $draft.tags, suggestions: knownTags)
            }
            Picker("Folder", selection: $draft.folderID) {
                Text("None").tag(UUID?.none)
                if !folders.isEmpty { Divider() }
                ForEach(folders) { folder in
                    Text(folder.name).tag(UUID?.some(folder.id))
                }
            }
        }
    }

    /// Everything but the choice hides while it is Never (docs/DESIGN.md, RD Gateway).
    private var gateway: some View {
        Section("Gateway") {
            Picker("Use a gateway", selection: $draft.gatewayUsage) {
                Text("Never").tag(Connection.Gateway.Usage.never)
                Text("Always").tag(Connection.Gateway.Usage.always)
            }
            if draft.gatewayUsage == .always {
                TextField("Gateway", text: $draft.gatewayAddress, prompt: Text("gateway.example.com"))
                problem(draft.gatewayProblem)
                Picker("Sign in to the gateway as", selection: $draft.gatewaySignIn) {
                    Text("Same as the Computer").tag(Connection.Gateway.SignIn.sameAsComputer)
                    Text("Another Account").tag(Connection.Gateway.SignIn.anotherAccount)
                }
                if draft.gatewaySignIn == .anotherAccount {
                    TextField("Gateway User", text: $draft.gatewayUsername, prompt: Text("Optional"))
                    TextField("Gateway Domain", text: $draft.gatewayDomain, prompt: Text("Optional"))
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
            Picker("Displays", selection: $draft.usesAllDisplays) {
                Text("This Display").tag(false)
                Text("All Displays").tag(true)
            }
            if let explanation = Self.displaysExplanation(
                allDisplays: draft.usesAllDisplays, separateSpaces: NSScreen.screensHaveSeparateSpaces
            ) {
                Text(explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What All Displays does, said beneath it (docs/DESIGN.md, Multiple displays).
    static func displaysExplanation(allDisplays: Bool, separateSpaces: Bool) -> String? {
        guard allDisplays else { return nil }
        let what = "The session fills every display in full screen, as one remote desktop."
        guard !separateSpaces else { return what }
        return what + " While “Displays have separate Spaces” is off in Desktop & Dock settings, "
            + "it uses only the display in front."
    }

    private var devices: some View {
        Section("Devices and Audio") {
            Toggle("Share clipboard", isOn: $draft.sharesClipboard)
            CopyFilesToggle(sharesClipboard: draft.sharesClipboard, copiesFiles: $draft.copiesFiles)
            Picker("Sound", selection: $draft.audioMode) {
                Text("Play on This Mac").tag(Connection.AudioMode.playOnThisMac)
                Text("Play on Remote Computer").tag(Connection.AudioMode.playOnRemote)
                Text("Off").tag(Connection.AudioMode.off)
            }
        }
    }

    private var sharedFolders: some View {
        Section {
            if draft.sharedFolders.isEmpty {
                Text("No folders are shared.")
                    .foregroundStyle(.secondary)
            }
            ForEach($draft.sharedFolders, id: \.path) { $folder in
                SharedFolderRow(folder: $folder) { draft.stopSharing(folder.path) }
            }
            Button("Add Folder…") { isChoosingFolders = true }
                .fileImporter(
                    isPresented: $isChoosingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true
                ) { result in
                    guard case .success(let urls) = result else { return }
                    draft.share(urls.compactMap { try? SharedFolderAccess.sharedFolder(for: $0) })
                }
        } header: {
            Text("Shared Folders")
        } footer: {
            Text("The remote computer sees only these folders, each as a drive named after the folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var security: some View {
        Section("Security") {
            Toggle("Reconnect if the connection drops", isOn: $draft.reconnectsAutomatically)
            Toggle("Require Network Level Authentication", isOn: $draft.requiresNLA)
            if let warning = draft.nlaWarning {
                Text(warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Certificate", selection: $draft.certificatePolicy) {
                Text("Ask on First Use").tag(Connection.CertificatePolicy.askOnFirstUse)
                Text("Require a Trusted Certificate").tag(Connection.CertificatePolicy.requireTrusted)
            }
            if draft.certificatePolicy == .requireTrusted {
                Text("Connects only when your Mac, or you before, already trusted the computer’s certificate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A problem, under the field it belongs to, once it is worth showing.
    @ViewBuilder
    private func problem(_ message: String?) -> some View {
        if showsProblems, let message {
            // Red marks it; the words stay in the label color, because red
            // text on a light form is below 4.5:1 (docs/DESIGN.md, Accessibility).
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
            .font(.callout)
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
