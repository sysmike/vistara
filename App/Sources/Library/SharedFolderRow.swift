import SwiftUI
import VistaraCore

/// One shared folder in the connection editor: what it is, whether the remote
/// computer may change it, and a way to stop sharing it.
struct SharedFolderRow: View {
    @Binding var folder: Connection.SharedFolder
    let stopSharing: () -> Void

    private var name: String {
        URL(fileURLWithPath: folder.path).lastPathComponent
    }

    var body: some View {
        let isMissing = SharedFolderAccess.resolve(folder) == nil
        HStack(spacing: 8) {
            Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "folder.fill")
                .foregroundStyle(isMissing ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if isMissing {
                    Text("Can’t find this folder. Remove it and add it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Long paths keep both ends: where it is and what it is.
                    Text(Self.displayPath(folder.path))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Toggle("Read only", isOn: $folder.isReadOnly)
                .toggleStyle(.checkbox)
                .accessibilityLabel("\(name) read only")
            Button(action: stopSharing) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop Sharing")
            .accessibilityLabel("Stop sharing \(name)")
        }
    }

    /// The path with the home folder shown as "~". Inside the App Sandbox
    /// NSHomeDirectory() is the app's container, so the real one is asked for.
    static func displayPath(_ path: String) -> String {
        guard let entry = getpwuid(getuid()), let home = String(validatingCString: entry.pointee.pw_dir),
            path == home || path.hasPrefix(home + "/")
        else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
