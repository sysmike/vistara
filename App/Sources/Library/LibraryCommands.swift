import AppKit
import SwiftUI

/// The connection commands in the menu bar, acting on the Connections window
/// in front (docs/DESIGN.md, menu table).
struct LibraryCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewConnectionMenuItem()
            ConnectMenuItem()
        }
        CommandGroup(after: .pasteboard) {
            ConnectionEditingMenuItems()
        }
        // SwiftUI adds no Window menu item for a Window scene, so this is
        // Vistara's own, as in Mail and Messages.
        CommandGroup(before: .windowArrangement) {
            ConnectionsWindowMenuItem()
            Divider()
        }
    }
}

/// Opens the connections window if needed, then the editor for a new connection.
private struct NewConnectionMenuItem: View {
    @FocusedValue(\.libraryActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Connection…") {
            if let newConnection = actions?.newConnection {
                newConnection()
            } else {
                openWindow(id: "connections")
                LibraryModel.shared.editorRequest = .new
            }
        }
        .keyboardShortcut("n")
    }
}

private struct ConnectMenuItem: View {
    @FocusedValue(\.libraryActions) private var actions

    var body: some View {
        Button("Connect") { actions?.connect?() }
            .keyboardShortcut("o")
            .disabled(actions?.connect == nil)
    }
}

private struct ConnectionEditingMenuItems: View {
    @FocusedValue(\.libraryActions) private var actions

    var body: some View {
        Divider()
        Button("Edit Connection…") { actions?.edit?() }
            .keyboardShortcut("i")
            .disabled(actions?.edit == nil)
        Button("Duplicate") { actions?.duplicate?() }
            .keyboardShortcut("d")
            .disabled(actions?.duplicate == nil)
        Button("Delete Connection") { deleteUnlessTyping() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(actions?.delete == nil)
        Divider()
        // In a session window Command-F goes to the remote computer instead.
        Button("Find") { actions?.find() }
            .keyboardShortcut("f")
            .disabled(actions == nil)
    }

    /// Command-Delete in a text field deletes to the start of the line, as
    /// everywhere on the Mac; only elsewhere does it delete connections.
    private func deleteUnlessTyping() {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
        } else {
            actions?.delete?()
        }
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
