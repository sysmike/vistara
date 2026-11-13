import AppKit
import SwiftUI
import VistaraCore

/// Says once, above the list, that some saved entries could not be read and
/// where the original file was kept. Not an alert: nothing is lost, and the
/// app is at launch (HIG Alerts: "Avoid showing an alert when your app starts").
struct SkippedEntriesNotice: View {
    let skipped: [LibraryCodec.SkippedEntry]
    let copy: URL?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.summary(of: skipped))
                if let copy {
                    Text("The original file was kept as “\(copy.lastPathComponent)”.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let copy {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([copy])
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .noticeBackground()
    }

    /// "2 connections and 1 folder couldn’t be read and were left out."
    static func summary(of skipped: [LibraryCodec.SkippedEntry]) -> String {
        let connections = skipped.filter { $0.kind == .connection }.count
        let folders = skipped.filter { $0.kind == .folder }.count
        let parts = [
            connections == 0 ? nil : connections == 1 ? "1 connection" : "\(connections) connections",
            folders == 0 ? nil : folders == 1 ? "1 folder" : "\(folders) folders"
        ].compactMap { $0 }
        let verb = connections + folders == 1 ? "was" : "were"
        return "\(parts.joined(separator: " and ")) couldn’t be read and \(verb) left out."
    }
}
