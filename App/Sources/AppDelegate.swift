import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let quitWithoutAskingKey = "QuitWithoutAsking"

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Vistara puts its own full-screen command in the View menu; this
        // keeps AppKit from adding a second one.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    }

    /// Quitting ends every chance to undo a deletion, so the Keychain items
    /// of deleted connections go now.
    func applicationWillTerminate(_ notification: Notification) {
        LibraryModel.shared.removeOrphanedCredentials(from: SessionCoordinator.shared.credentialStore)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = SessionCoordinator.shared
        let count = coordinator.liveSessionCount
        guard count > 0 else { return .terminateNow }

        if !UserDefaults.standard.bool(forKey: Self.quitWithoutAskingKey) {
            let alert = NSAlert()
            alert.messageText = count == 1
                ? "Quit Vistara and disconnect 1 session?"
                : "Quit Vistara and disconnect \(count) sessions?"
            alert.informativeText = "Programs on the remote computers keep running. You can reconnect later."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.quitWithoutAskingKey)
            }
        }

        // Give the sessions a moment to say goodbye to their servers.
        Task {
            await coordinator.disconnectAll(timeout: .seconds(1))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
