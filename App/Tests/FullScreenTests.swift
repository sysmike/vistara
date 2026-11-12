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

    /// What the menu bar holds, for a failure message.
    private func describeMenuBar() -> String {
        (NSApp.mainMenu?.items ?? []).map { top in
            let entries = (top.submenu?.items ?? []).map { item in
                item.isSeparatorItem ? "—" : "\(item.title)<\(item.action.map(NSStringFromSelector) ?? "nil")>"
            }
            return "\(top.title): " + entries.joined(separator: ", ")
        }.joined(separator: " | ")
    }

    @Test
    func theViewMenuHasOneFullScreenCommandForTheSessionWindow() async throws {
        let coordinator = SessionCoordinator(
            credentialStore: InMemoryCredentialStore(), trustStore: temporaryTrustStore()
        )
        let controller = coordinator.open(Self.nowhere)
        defer { controller.window.close() }
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
        await waitUntil("the session window is main") { coordinator.activeModel === controller.model }
        try await Task.sleep(for: .milliseconds(300))

        let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        view.delegate?.menuNeedsUpdate?(view)
        view.update()
        let fullScreen = items(in: NSApp.mainMenu).filter {
            $0.action == #selector(NSWindow.toggleFullScreen(_:)) || $0.title.hasSuffix("Full Screen")
        }
        let context: Comment = "menu bar: \(describeMenuBar())"
        #expect(fullScreen.count == 1, context)
        let item = try #require(fullScreen.first, context)
        #expect(item.menu === view)
        #expect(item.title == "Enter Full Screen")
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.control, .command])
    }

    /// Answers the certificate question and waits until connected.
    private func waitForConnection(_ model: SessionModel) async {
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.trustOnce)
        await waitUntil("the session is connected") { model.phase == .connected }
    }

    /// Whether the remote desktop fills the window's content pixel for pixel.
    private func desktopFills(_ window: NSWindow, of model: SessionModel) -> Bool {
        guard let wanted = DesktopSize.filling(
            viewSize: window.contentLayoutRect.size, backingScale: window.backingScaleFactor, usesHiDPI: true
        ), let size = model.framebuffer?.size else { return false }
        return size.width == Int(wanted.width) && size.height == Int(wanted.height)
    }

    /// The full-screen notifications a window posts, for failure messages.
    private final class TransitionLog {
        private(set) var names: [String] = []
        private var observers: [NSObjectProtocol] = []

        init(window: NSWindow) {
            let center = NotificationCenter.default
            let watched: [Notification.Name] = [
                NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification
            ]
            observers = watched.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.names.append(note.name.rawValue) }
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    /// For failure messages.
    private func describe(_ window: NSWindow, of model: SessionModel) -> String {
        "key \(window.isKeyWindow), main \(window.isMainWindow), sheet \(window.attachedSheet != nil), "
            + "visible \(window.isVisible), app active \(NSApp.isActive), full screen \(model.isFullScreen), "
            + "style \(String(window.styleMask.rawValue, radix: 16))"
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
        await waitForConnection(model)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        coordinator.toggleFullScreen(model)
        await waitUntil("the window is in full screen", within: .seconds(20)) {
            window.styleMask.contains(.fullScreen) && model.isFullScreen
        }
        try #require(window.styleMask.contains(.fullScreen))

        // The remote desktop follows, pixel for pixel.
        await waitUntil("the desktop fills the screen") { desktopFills(window, of: model) }
        let screen = try #require(window.screen)
        #expect(window.frame.size == screen.frame.size)

        // The session ends; the window stays in full screen and says why.
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.styleMask.contains(.fullScreen))
        #expect(window.isVisible)

        // Reconnecting from there connects at the full-screen size.
        model.reconnect()
        await waitForConnection(model)
        await waitUntil("the reconnected desktop fills the screen") { desktopFills(window, of: model) }

        // Leaving full screen is the user's choice, and the desktop follows back.
        let transitions = TransitionLog(window: window)
        let before = describe(window, of: model)
        coordinator.toggleFullScreen(model)
        await waitUntil("the window has left full screen", within: .seconds(20)) {
            !window.styleMask.contains(.fullScreen) && !model.isFullScreen
        }
        #expect(
            !model.isFullScreen && !window.styleMask.contains(.fullScreen),
            "before: \(before); after: \(describe(window, of: model)); notifications: \(transitions.names)"
        )
        await waitUntil("the desktop fills the window again") { desktopFills(window, of: model) }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }
}
