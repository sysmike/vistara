import SwiftUI

@main
struct VistaraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SessionCoordinator.shared
    @State private var library = LibraryModel.standard()

    var body: some Scene {
        // The primary window, one per app. Window > Connections (Command-0)
        // brings it back; see LibraryCommands.
        Window("Connections", id: "connections") {
            ConnectionsView(model: library) { connection in
                coordinator.open(SessionTarget(connection: connection))
                Task { await library.recordConnection(connection.id) }
            }
            .task { await library.load() }
        }
        .defaultSize(width: 780, height: 480)
        .commands {
            SidebarCommands()
            LibraryCommands()
            SessionCommands(coordinator: coordinator)
        }

        // The other panes arrive with issue #30.
        Settings {
            SecuritySettingsView(trustStore: coordinator.trustStore)
        }
    }
}
