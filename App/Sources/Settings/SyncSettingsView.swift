import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VistaraCore

/// Settings > Sync: whether the connections are kept on this Mac only or in
/// a folder other Macs share, which folder, and whether it can be reached
/// (docs/DESIGN.md, Connections on several Macs).
struct SyncSettingsView: View {
    let model: LibraryModel
    /// Asks for the folder; the open panel, but for tests.
    var chooseFolder: @MainActor () -> URL? = SyncSettingsView.askForFolder
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Picker("Keep connections", selection: keepsInFolder) {
                    Text("On This Mac").tag(false)
                    Text("In a Folder…").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(!model.canChange)
                if let folder = model.syncFolder {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            FolderLabel(folder: folder)
                            Spacer(minLength: 8)
                            Button("Choose…", action: choose)
                                .disabled(!model.canChange)
                        }
                    }
                    LabeledContent("Status") {
                        SyncStatusLabel(state: model.syncState)
                    }
                }
                if let failure {
                    Text(failure)
                        .settingsFootnote()
                }
            } footer: {
                Text("Every Mac that keeps its connections in the same folder, such as one in iCloud Drive, has the "
                    + "same connections. Passwords, trusted certificates, shared folders, when a connection was "
                    + "last used, and Settings stay on each Mac.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Choosing In a Folder… asks for the folder; cancelling stays on this Mac.
    private var keepsInFolder: Binding<Bool> {
        Binding {
            model.syncFolder != nil
        } set: { inFolder in
            if inFolder {
                choose()
            } else {
                failure = nil
                Task { await model.keepOnThisMac() }
            }
        }
    }

    private func choose() {
        guard let url = chooseFolder() else { return }
        failure = nil
        Task {
            do {
                try await model.keepInFolder(url)
            } catch {
                failure = "Vistara can’t keep your connections in “\(url.lastPathComponent)”. "
                    + "Choose a folder you can change."
            }
        }
    }

    /// The open panel, starting in iCloud Drive where there is one.
    static func askForFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to keep your connections in. Other Macs that choose it have the same "
            + "connections."
        panel.directoryURL = SyncFolderChoice.iCloudDrive
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The folder's icon, name, and where it is.
private struct FolderLabel: View {
    let folder: SyncFolderChoice

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name)
                Text(folder.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(folder.path)
        .accessibilityElement(children: .combine)
    }
}

/// Whether the folder can be used, as a symbol and words.
private struct SyncStatusLabel: View {
    let state: SyncedLibraryStore.FolderState?

    var body: some View {
        switch state {
        case nil:
            Label("Checking…", systemImage: "clock")
        case .reachable:
            Label {
                Text("Up to date")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .unreachable:
            Label {
                Text("Can’t be reached. Changes wait on this Mac.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        case .newerLayout:
            Label {
                Text("Set up by a newer Vistara. Update Vistara to use it.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
