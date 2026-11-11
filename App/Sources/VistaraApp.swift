import SwiftUI

@main
struct VistaraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView(
                "No Connections",
                systemImage: "desktopcomputer",
                description: Text("Connections you add will appear here.")
            )
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}
