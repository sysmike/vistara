import AppKit
import RDPKit
import SwiftUI

/// A paste of the remote computer's files that is under way.
@MainActor
@Observable
final class FilePasteProgress {
    let computerName: String
    /// The items being pasted, as the remote computer named them.
    let itemNames: [String]
    var progress = RDPFileFetchProgress(bytesReceived: 0, bytesExpected: 0, filesDone: 0, fileCount: 0)
    @ObservationIgnored let cancel: () -> Void

    init(computerName: String, itemNames: [String], cancel: @escaping () -> Void) {
        self.computerName = computerName
        self.itemNames = itemNames
        self.cancel = cancel
    }

    /// “Copying “Report.pdf” from “Build Server”” or, for several items,
    /// “Copying 3 items from “Build Server””.
    var title: String {
        let what = itemNames.count == 1 ? "“\(itemNames[0])”" : "\(itemNames.count) items"
        return "Copying \(what) from “\(computerName)”"
    }

    /// “12.3 MB of 45.6 MB”, once the size is known.
    var detail: String {
        guard progress.bytesExpected > 0 else { return "Preparing…" }
        let received = Int64(clamping: progress.bytesReceived).formatted(.byteCount(style: .file))
        let expected = Int64(clamping: progress.bytesExpected).formatted(.byteCount(style: .file))
        return "\(received) of \(expected)"
    }
}

/// What a paste of the remote computer's files shows while it runs.
struct FilePasteProgressView: View {
    let paste: FilePasteProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(paste.title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            ProgressView(value: paste.progress.fractionCompleted)
                .accessibilityLabel(paste.title)
                .accessibilityValue(paste.detail)
            HStack {
                Text(paste.detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: paste.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Shows a paste's progress in a small panel that floats above other apps'
/// windows, because the app pasting is in front, not Vistara. Clicking it
/// does not bring Vistara forward.
@MainActor
final class FilePastePanel {
    private var panel: NSPanel?

    func show(_ paste: FilePasteProgress?) {
        guard let paste else {
            panel?.close()
            panel = nil
            return
        }
        let hosting = NSHostingView(rootView: FilePasteProgressView(paste: paste))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        panel.orderFrontRegardless()
        self.panel?.close()
        self.panel = panel
    }
}
