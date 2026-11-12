import RDPKit
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

        // Control-Option-Delete: the same keys by their Mac names.
        Button("Send Ctrl+Alt+Del") { model?.send(RDPInputEvent.controlAltDelete) }
            .keyboardShortcut(.delete, modifiers: [.control, .option])
            .disabled(model?.isConnected != true)
        // The Windows key has no free counterpart on a Mac keyboard.
        Button("Send Windows Key") { model?.send(RDPInputEvent.tap(.leftWindows)) }
            .disabled(model?.isConnected != true)
    }
}
