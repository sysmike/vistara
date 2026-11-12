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
        // SwiftUI adds no Window menu item for a Window scene, so this is
        // Vistara's own, as in Mail and Messages.
        CommandGroup(before: .windowArrangement) {
            ConnectionsWindowMenuItem()
            Divider()
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

/// Opens the connections window, or brings it forward.
private struct ConnectionsWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Connections") { openWindow(id: "connections") }
            .keyboardShortcut("0")
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
