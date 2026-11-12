import AppKit
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// Full screen is the system's, and the session lives on inside it.
@Suite(.serialized)
@MainActor
struct FullScreenTests {
    private static let nowhere = SessionTarget(name: "Nowhere", host: "127.0.0.1", port: 1)

    /// Every menu item, however deep.
    private func items(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items(in: $0.submenu) }
    }

    @Test
    func theSessionWindowCanUseTheSystemsFullScreen() {
        let model = SessionModel(
            target: Self.nowhere, credentialStore: InMemoryCredentialStore(), phase: .disconnected(.userRequested)
        )
        let controller = SessionWindowController(model: model)
        #expect(controller.window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(controller.window.standardWindowButton(.zoomButton)?.isEnabled == true)
        controller.window.close()
    }

    @Test
    func theMenuBarHasOneFullScreenCommand() {
        let fullScreen = items(in: NSApp.mainMenu).filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
        let described = fullScreen.map {
            "\($0.title) [\($0.keyEquivalent)] \(String($0.keyEquivalentModifierMask.rawValue, radix: 16)) "
                + "in \($0.menu?.title ?? "?")"
        }
        #expect(fullScreen.count == 1, "full screen items: \(described)")
        #expect(fullScreen.first?.menu?.title == "View", "full screen items: \(described)")
    }

    @Test(.enabled(if: TestServer.current != nil && NSScreen.main != nil))
    func theDesktopFillsTheScreenAndTheSessionStaysInFullScreenAfterADisconnect() async throws {
        let server = try #require(TestServer.current)
        let coordinator = SessionCoordinator(
            credentialStore: try server.storeWithCredentials(), trustStore: temporaryTrustStore()
        )
        let controller = coordinator.open(server.address)
        let model = controller.model
        let window = controller.window
        defer { window.close() }

        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.trustOnce)
        await waitUntil("the session is connected") { model.phase == .connected }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        await waitUntil("the window is in full screen", within: .seconds(20)) {
            window.styleMask.contains(.fullScreen)
        }
        try #require(window.styleMask.contains(.fullScreen))

        // The remote desktop follows, pixel for pixel.
        func fillsTheWindow() -> Bool {
            guard let wanted = DesktopSize.filling(
                viewSize: window.contentLayoutRect.size, backingScale: window.backingScaleFactor, usesHiDPI: true
            ), let size = model.framebuffer?.size else { return false }
            return size.width == Int(wanted.width) && size.height == Int(wanted.height)
        }
        await waitUntil("the desktop fills the screen") { fillsTheWindow() }
        let screen = try #require(window.screen)
        #expect(window.frame.size == screen.frame.size)

        // The session ends; the window stays in full screen and says why.
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.styleMask.contains(.fullScreen))
        #expect(window.isVisible)

        // Reconnecting from there connects at the full-screen size at once.
        model.reconnect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.trustOnce)
        await waitUntil("the session is connected") { model.phase == .connected }
        #expect(fillsTheWindow())

        // Leaving full screen is the user's choice, and the desktop follows back.
        window.toggleFullScreen(nil)
        await waitUntil("the window has left full screen", within: .seconds(20)) {
            !window.styleMask.contains(.fullScreen)
        }
        await waitUntil("the desktop fills the window again") { fillsTheWindow() }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }
}
