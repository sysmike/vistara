import AppKit
import Testing
import VistaraCore
@testable import Vistara

/// The window tells its session whether anyone can see it, so that the server
/// stops sending a screen nobody looks at (#103).
@Suite(.serialized)
@MainActor
struct SessionVisibilityTests {
    private func controller(_ name: String, host: String) -> SessionWindowController {
        let target = SessionTarget(name: name, host: host, port: 3389)
        let model = SessionModel(
            target: target, credentialStore: InMemoryCredentialStore(), phase: .disconnected(.userRequested)
        )
        return SessionWindowController(model: model)
    }

    @Test
    func aMinimizedWindowIsNotVisible() async {
        let session = controller("Build Server", host: "build01")
        defer { session.window.close() }
        NSApp.activate(ignoringOtherApps: true)
        session.show()
        await waitUntil("the window can be seen") { session.model.isVisible }

        session.window.miniaturize(nil)
        await waitUntil("the minimized window can no longer be seen") { !session.model.isVisible }
        session.window.deminiaturize(nil)
        await waitUntil("the window can be seen again") { session.model.isVisible }
    }

    @Test
    func aBackgroundTabIsNotVisible() async {
        let front = controller("Build Server", host: "build01")
        let back = controller("Jump Host", host: "jump")
        defer {
            for session in [front, back] where session.window.isVisible { session.window.close() }
        }
        NSApp.activate(ignoringOtherApps: true)
        front.show()
        front.window.addTabbedWindow(back.window, ordered: .above)
        front.window.makeKeyAndOrderFront(nil)
        await waitUntil("the background tab is out of sight") { front.model.isVisible && !back.model.isVisible }

        back.window.makeKeyAndOrderFront(nil)
        await waitUntil("the tabs have swapped") { back.model.isVisible && !front.model.isVisible }
    }
}
