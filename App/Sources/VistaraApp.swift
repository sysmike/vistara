import SwiftUI

@main
struct VistaraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SessionCoordinator.shared
    @State private var library = LibraryModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // The primary window, one per app. Window > Connections (Command-0)
        // brings it back; see LibraryCommands.
        Window("Connections", id: "connections") {
            ConnectionsView(model: library) { connection in
                coordinator.open(SessionTarget(connection: connection))
                Task { await library.recordConnection(connection.id) }
            } saved: { connection in
                coordinator.connectionChanged(SessionTarget(connection: connection))
            }
            .task {
                await library.load()
                // Nothing from an earlier run can be undone any more.
                library.removeOrphanedCredentials(from: coordinator.credentialStore)
                coordinator.editConnection = { id in
                    openWindow(id: "connections")
                    library.editorRequest = .edit(id)
                }
            }
        }
        .defaultSize(width: 780, height: 480)
        .commands {
            SidebarCommands()
            LibraryCommands()
            SessionCommands(coordinator: coordinator)
        }

        Settings {
            SettingsView(trustStore: coordinator.trustStore)
        }
    }
}
