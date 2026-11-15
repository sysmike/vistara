import AppKit
import SwiftUI
import VistaraCore

/// Says above the list when the folder chosen in Settings > Sync can't be
/// used, and that the connections shown are this Mac's copy. It stays while
/// that is so, and goes by itself when the folder is back.
struct SyncNotice: View {
    let folder: SyncFolderChoice
    let state: SyncedLibraryStore.FolderState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            // Laid out as the other notices are: a text that fixes its own
            // height kept the whole window from drawing.
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.message(folder: folder.name, state: state))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Sync Settings…") {
                UserDefaults.standard.set(SettingsView.Pane.sync.rawValue, forKey: SettingsView.paneKey)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .noticeBackground()
    }

    static func message(folder: String, state: SyncedLibraryStore.FolderState) -> String {
        switch state {
        case .reachable:
            ""
        case .unreachable:
            "The folder “\(folder)” can’t be reached, so these are your connections as this Mac last saw them. "
                + "Your changes are kept and written to the folder when it’s back."
        case .newerLayout:
            "The folder “\(folder)” was set up by a newer version of Vistara, so your changes stay on this Mac. "
                + "Update Vistara to keep your connections in the folder."
        }
    }
}
