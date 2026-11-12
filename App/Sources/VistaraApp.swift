import SwiftUI

@main
struct VistaraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SessionCoordinator.shared

    var body: some Scene {
        // Temporary: the connections window (issue #21) replaces this launcher.
        WindowGroup("Connect", id: "launcher") {
            LauncherView { target in
                coordinator.open(target)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            SessionCommands(coordinator: coordinator)
        }

        // The other panes arrive with issue #30.
        Settings {
            SecuritySettingsView(trustStore: coordinator.trustStore)
        }
    }
}
