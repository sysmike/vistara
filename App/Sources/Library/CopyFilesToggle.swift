import SwiftUI

/// Copy files, beneath Share clipboard (docs/DESIGN.md, Copying files). It
/// needs Share clipboard: without it, it is dimmed and shown off, and what
/// was chosen comes back when the clipboard is shared again.
struct CopyFilesToggle: View {
    let sharesClipboard: Bool
    @Binding var copiesFiles: Bool

    var body: some View {
        Toggle(isOn: Binding(get: { sharesClipboard && copiesFiles }, set: { copiesFiles = $0 })) {
            Text("Copy files")
                .padding(.leading, 16)
        }
        .disabled(!sharesClipboard)
    }
}
