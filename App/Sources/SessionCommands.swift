import RDPKit
import SwiftUI

/// The Session menu. It acts on the session in the main window.
struct SessionCommands: Commands {
    let coordinator: SessionCoordinator

    var body: some Commands {
        // AppKit adds no full-screen command of its own here, so the View menu
        // would otherwise be empty.
        CommandGroup(after: .toolbar) {
            FullScreenMenuItem(coordinator: coordinator)
        }
        CommandMenu("Session") {
            SessionMenuItems(coordinator: coordinator)
        }
        // Right after File > Close, which AppKit names Close Tab in a tabbed
        // window (HIG The menu bar, File menu).
        CommandGroup(after: .saveItem) {
            CloseWindowMenuItem(coordinator: coordinator)
        }
    }
}

/// File > Close Window: the session window in front with all its tabs.
private struct CloseWindowMenuItem: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let model = coordinator.activeModel
        Button("Close Window") {
            if let model { coordinator.closeWindow(of: model) }
        }
        .keyboardShortcut("w", modifiers: [.shift, .command])
        .disabled(model == nil)
    }
}

/// View > Enter Full Screen, for the session in the main window. Only
/// session windows can be full screen.
private struct FullScreenMenuItem: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let model = coordinator.activeModel
        Button(model?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen") {
            if let model { coordinator.toggleFullScreen(model) }
        }
        .keyboardShortcut("f", modifiers: [.control, .command])
        .disabled(model == nil)
    }
}

private struct SessionMenuItems: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let model = coordinator.activeModel

        // While reconnecting by itself: try now instead of waiting.
        Button("Reconnect") { model?.reconnect() }
            .keyboardShortcut("r")
            .disabled(model.map { $0.isLive && !$0.phase.isReconnecting } ?? true)
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
