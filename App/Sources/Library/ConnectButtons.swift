import SwiftUI

/// Connect, and with Option the same in the other place: Connect in New Tab
/// or Connect in New Window (docs/DESIGN.md, Session tabs). From macOS 15 the
/// second is the first's alternate, shown while Option is held, as Mac menus
/// do; before, it is an item of its own.
struct ConnectButtons: View {
    let alternate: SessionPlacement
    /// File > Connect has Command-O and Option-Command-O; a context menu none.
    var hasShortcuts = false
    /// Called with nil for Connect, or the alternate's placement.
    let connect: (SessionPlacement?) -> Void

    var body: some View {
        if #available(macOS 15, *) {
            primary.modifierKeyAlternate(.option) { elsewhere }
        } else {
            primary
            elsewhere
        }
    }

    private var primary: some View {
        Button("Connect") { connect(nil) }
            .keyboardShortcut(hasShortcuts ? KeyboardShortcut("o") : nil)
    }

    private var elsewhere: some View {
        Button(alternate.connectTitle) { connect(alternate) }
            .keyboardShortcut(hasShortcuts ? KeyboardShortcut("o", modifiers: [.command, .option]) : nil)
    }
}
