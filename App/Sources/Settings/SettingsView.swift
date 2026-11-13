import SwiftUI
import VistaraCore

/// The Settings window: a fixed toolbar of panes, the title following the
/// pane, reopening on the last one (docs/DESIGN.md, Settings).
struct SettingsView: View {
    enum Pane: String {
        case general, keyboard, security
    }

    static let paneKey = "SettingsPane"

    let trustStore: CertificateTrustStore
    @AppStorage(Self.paneKey) private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general)
            KeyboardSettingsView()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag(Pane.keyboard)
            SecuritySettingsView(trustStore: trustStore)
                .tabItem { Label("Security", systemImage: "lock") }
                .tag(Pane.security)
        }
    }
}

/// Settings > General: what new connections start with, and quitting.
struct GeneralSettingsView: View {
    @State private var defaults = NewConnectionDefaults.load()
    @AppStorage(AppDelegate.quitWithoutAskingKey) private var quitsWithoutAsking = false

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $defaults.resolutionMode) {
                    Text("Match Window").tag(Connection.ResolutionMode.matchWindow)
                    Text("Keep Size, Scale to Fit").tag(Connection.ResolutionMode.scaleToFit)
                }
                Toggle("Optimize for Retina displays", isOn: $defaults.usesHiDPI)
                Picker("Displays", selection: $defaults.usesAllDisplays) {
                    Text("This Display").tag(false)
                    Text("All Displays").tag(true)
                }
                Toggle("Share clipboard", isOn: $defaults.sharesClipboard)
                Picker("Sound", selection: $defaults.audioMode) {
                    Text("Play on This Mac").tag(Connection.AudioMode.playOnThisMac)
                    Text("Play on Remote Computer").tag(Connection.AudioMode.playOnRemote)
                    Text("Off").tag(Connection.AudioMode.off)
                }
                Toggle("Reconnect if the connection drops", isOn: $defaults.reconnectsAutomatically)
                Toggle("Require Network Level Authentication", isOn: $defaults.requiresNLA)
                Picker("Certificate", selection: $defaults.certificatePolicy) {
                    Text("Ask on First Use").tag(Connection.CertificatePolicy.askOnFirstUse)
                    Text("Require a Trusted Certificate").tag(Connection.CertificatePolicy.requireTrusted)
                }
            } header: {
                Text("New Connections")
            } footer: {
                Text("New connections start with these settings. Each connection can change them in its editor.")
                    .settingsFootnote()
            }
            Section("Quitting") {
                Toggle(
                    "Ask before quitting with open sessions",
                    isOn: Binding(get: { !quitsWithoutAsking }, set: { quitsWithoutAsking = !$0 })
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: defaults) { defaults.save() }
    }
}

/// Settings > Keyboard: which Mac shortcuts reach the remote computer.
struct KeyboardSettingsView: View {
    static let rightCommandKey = "RightCommandIsWindowsKey"

    @AppStorage("TranslateEditingShortcuts") private var translatesEditingShortcuts = true
    @AppStorage(Self.rightCommandKey) private var rightCommandIsWindowsKey = false

    var body: some View {
        Form {
            Section {
                Toggle("Send editing shortcuts as Control shortcuts", isOn: $translatesEditingShortcuts)
                Text("Command-C, Command-V, Command-Z and the other editing shortcuts reach the remote computer as "
                    + "Control-C, Control-V, and so on. Other Command shortcuts stay with your Mac.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Use Right Command as the Windows key", isOn: $rightCommandIsWindowsKey)
                Text("Right Command and the keys pressed with it go to the remote computer, so Right Command-R "
                    + "opens Run. Left Command keeps working on your Mac. Session > Send Windows Key works either way.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// An explanation under a setting.
    func settingsFootnote() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
