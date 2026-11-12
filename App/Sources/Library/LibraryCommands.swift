import SwiftUI

/// File > New Connection and Edit > Find, for the connections window.
struct LibraryCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewConnectionMenuItem()
        }
        CommandGroup(after: .pasteboard) {
            FindMenuItem()
        }
    }
}

/// Opens the connections window if needed, then the New Connection sheet.
private struct NewConnectionMenuItem: View {
    @FocusedValue(\.libraryActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Connection…") {
            if let newConnection = actions?.newConnection {
                newConnection()
            } else {
                openWindow(id: "connections")
            }
        }
        .keyboardShortcut("n")
    }
}

/// Focuses the search field of the connections window in front. In a session
/// window Command-F goes to the remote computer instead (see docs/DESIGN.md).
private struct FindMenuItem: View {
    @FocusedValue(\.libraryActions) private var actions

    var body: some View {
        Divider()
        Button("Find") { actions?.find() }
            .keyboardShortcut("f")
            .disabled(actions == nil)
    }
}
