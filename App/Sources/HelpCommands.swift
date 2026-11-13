import AppKit
import SwiftUI

/// Help > Vistara Help opens the user guide in the browser. It replaces the
/// item SwiftUI adds, which only says that help isn't available.
struct HelpCommands: Commands {
    static let guide = URL(string: "https://github.com/sysmike/vistara/blob/main/docs/USER-GUIDE.md")

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Vistara Help") {
                if let guide = Self.guide { NSWorkspace.shared.open(guide) }
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
