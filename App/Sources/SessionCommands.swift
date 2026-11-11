import SwiftUI

/// The Session menu. It acts on the session in the main window.
struct SessionCommands: Commands {
    let coordinator: SessionCoordinator

    var body: some Commands {
        CommandMenu("Session") {
            SessionMenuItems(coordinator: coordinator)
        }
    }
}

private struct SessionMenuItems: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let model = coordinator.activeModel

        Button("Reconnect") { model?.reconnect() }
            .keyboardShortcut("r")
            .disabled(model?.isLive != false)
        // Same as closing the window.
        Button("Disconnect") {
            if let model { coordinator.disconnect(model) }
        }
            .disabled(model?.isLive != true)

        Divider()

        // Sent to the remote computer once keyboard input exists (issue #11).
        Button("Send Ctrl+Alt+Del") {}
            .keyboardShortcut(.delete, modifiers: [.control, .option])
            .disabled(true)
    }
}
