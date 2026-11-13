import AppKit
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// Session windows grouped as tabs (docs/DESIGN.md, Session tabs; #99).
@Suite(.serialized)
@MainActor
struct SessionTabsTests {
    private func controller(_ name: String, host: String, phase: SessionModel.Phase = .disconnected(.userRequested))
        -> SessionWindowController {
        let target = SessionTarget(name: name, host: host, port: 3389)
        let model = SessionModel(target: target, credentialStore: InMemoryCredentialStore(), phase: phase)
        return SessionWindowController(model: model)
    }

    /// Two session windows as one tab group, the first in front.
    private func tabGroup(_ first: SessionWindowController, _ second: SessionWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        first.show()
        first.window.addTabbedWindow(second.window, ordered: .above)
        first.window.makeKeyAndOrderFront(nil)
    }

    private func close(_ controllers: SessionWindowController...) {
        for controller in controllers where controller.window.isVisible {
            controller.window.close()
        }
    }

    @Test
    func sessionWindowsGroupOnlyWithEachOther() {
        let first = controller("Build Server", host: "build01.example.com")
        let second = controller("Jump Host", host: "jump.example.com")
        defer { close(first, second) }
        #expect(first.window.tabbingMode == .automatic)
        #expect(first.window.tabbingIdentifier == SessionWindowController.tabbingIdentifier)
        #expect(second.window.tabbingIdentifier == first.window.tabbingIdentifier)

        tabGroup(first, second)
        #expect(first.window.tabbedWindows?.count == 2)

        // Any other window, the Connections window among them, refuses.
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        SessionWindow.refuseTabbing(other)
        #expect(other.tabbingMode == .disallowed)
        SessionWindow.refuseTabbing(first.window)
        #expect(first.window.tabbingMode == .automatic)
        let connections = NSApp.windows.filter { $0.identifier?.rawValue.contains("connections") == true }
        #expect(connections.allSatisfy { $0.tabbingMode == .disallowed })
    }

    /// Only the tab in front has the keyboard and is offered the clipboard.
    @Test
    func onlyTheTabInFrontIsInFront() async {
        let first = controller("Build Server", host: "build01.example.com")
        let second = controller("Jump Host", host: "jump.example.com")
        defer { close(first, second) }
        tabGroup(first, second)
        await waitUntil("the first tab is key") { first.window.isKeyWindow }
        #expect(first.model.isInFront())
        #expect(!second.model.isInFront())

        second.window.makeKeyAndOrderFront(nil)
        await waitUntil("the second tab is key") { second.window.isKeyWindow }
        #expect(second.model.isInFront())
        #expect(!first.model.isInFront())
    }

    /// A tab brought to the front has the group's size, which its desktop
    /// then follows.
    @Test
    func aTabBroughtToTheFrontHasTheGroupsSize() async {
        let first = controller("Build Server", host: "build01.example.com")
        let second = controller("Jump Host", host: "jump.example.com")
        defer { close(first, second) }
        tabGroup(first, second)
        first.window.setContentSize(NSSize(width: 900, height: 600))
        second.window.makeKeyAndOrderFront(nil)
        await waitUntil("the second tab is key") { second.window.isKeyWindow }
        #expect(second.window.frame.size == first.window.frame.size)
        #expect(second.model.windowDesktopSize?() == first.model.windowDesktopSize?())
    }

    /// A frame is remembered for a computer only while its session is alone:
    /// AppKit's own autosaving, after a move.
    @Test
    func aTabbedWindowDoesNotSaveItsFrame() async throws {
        let host = "frame-\(UUID().uuidString).example.com"
        let first = controller("Alone", host: host)
        let second = controller("Other", host: "other.example.com")
        defer { close(first, second) }
        let key = "NSWindow Frame Session \(host):3389"
        NSApp.activate(ignoringOtherApps: true)
        first.show()
        first.window.setFrame(NSRect(x: 100, y: 100, width: 700, height: 500), display: true)
        try await Task.sleep(for: .milliseconds(300))
        let alone = UserDefaults.standard.string(forKey: key)
        #expect(alone == first.window.frameDescriptor, "autosaved while alone")

        tabGroup(first, second)
        first.window.setFrame(NSRect(x: 120, y: 120, width: 900, height: 640), display: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(UserDefaults.standard.string(forKey: key) == alone, "unchanged while tabbed")
    }

    /// File > Close Window closes every tab, and each tab's session.
    @Test
    func closeWindowClosesEveryTab() async {
        let coordinator = SessionCoordinator(
            credentialStore: InMemoryCredentialStore(), trustStore: temporaryTrustStore()
        )
        let first = coordinator.open(SessionTarget(name: "Nowhere", host: "127.0.0.1", port: 1))
        let second = coordinator.open(SessionTarget(name: "Nowhere Else", host: "127.0.0.1", port: 2))
        tabGroup(first, second)
        #expect(coordinator.sessionWindows.count == 2)
        coordinator.closeWindow(of: first.model)
        await waitUntil("both tabs are closed") { coordinator.sessionWindows.isEmpty }
        #expect(!first.window.isVisible && !second.window.isVisible)
    }

    /// What File > Close is called in a tabbed session window, for the
    /// design's menu table: AppKit names it.
    @Test
    func fileCloseIsCloseTabInATabbedWindow() async throws {
        let first = controller("Build Server", host: "build01.example.com")
        let second = controller("Jump Host", host: "jump.example.com")
        defer { close(first, second) }
        tabGroup(first, second)
        await waitUntil("the first tab is key") { first.window.isKeyWindow }
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        file.update()
        let close = file.items.first { $0.action == #selector(NSWindow.performClose(_:)) }
        #expect(close?.title == "Close Tab", "File menu: \(file.items.map(\.title))")
        // Another window in front: Close again.
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        await waitUntil("the other window is key") { other.isKeyWindow }
        file.update()
        #expect(close?.title == "Close")

        let closeWindow = file.items.first {
            $0.title == "Close Window" && $0.keyEquivalentModifierMask.contains(.shift)
        }
        #expect(closeWindow?.keyEquivalent == "w")
    }

    /// Two live sessions in one window: closing one tab ends only its session.
    @Test(.enabled(if: TestServer.isFreeRDPTestServer), .timeLimit(.minutes(1)))
    func closingATabEndsOnlyItsSession() async throws {
        let server = try #require(TestServer.current)
        let models = try (0..<2).map { _ in
            SessionModel(target: server.address, credentialStore: try server.storeWithCredentials())
        }
        let controllers = models.map(SessionWindowController.init(model:))
        defer { controllers.forEach { if $0.window.isVisible { $0.window.close() } } }
        tabGroup(controllers[0], controllers[1])
        for model in models {
            model.connect()
            await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
            model.answerCertificate(.trustOnce)
            await waitUntil("the session is connected") { model.phase == .connected }
        }

        controllers[1].window.close()
        await waitUntil("the closed tab's session has ended") { !models[1].isLive }
        try await Task.sleep(for: .milliseconds(500))
        #expect(models[0].phase == .connected)
        #expect(controllers[0].window.isVisible)
        models[0].disconnect()
        await waitUntil("the session has ended") { !models[0].isLive }
    }

    /// A key press as AppKit delivers it: through the application, so the
    /// window's and the menus' key equivalents get their turn.
    private func press(
        _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, in window: NSWindow
    ) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            NSApp.sendEvent(event)
        }
    }

    /// Control-Tab reaches a session that has the keyboard instead of
    /// switching tabs; Shift-Command-] and [ switch tabs (#101).
    @Test
    func controlTabGoesToTheSessionAndShiftCommandBracketsSwitchTabs() async throws {
        let first = controller("Build Server", host: "build01.example.com")
        let second = controller("Jump Host", host: "jump.example.com")
        defer { close(first, second) }
        let session = RDPSessionView(framebuffer: RDPFramebuffer(), connectionName: "Build Server")
        var sent: [RDPInputEvent] = []
        session.inputHandler = { sent.append(contentsOf: $0) }
        first.window.contentView = session
        tabGroup(first, second)
        await waitUntil("the first tab has the keyboard") {
            first.window.isKeyWindow && first.window.firstResponder === session
        }
        let tabGroup = try #require(first.window.tabGroup)
        let tab = RDPScancode(0x0F)

        try press(0x30, "\t", .control, in: first.window)
        try press(0x30, "\t", [.control, .shift], in: first.window)
        #expect(tabGroup.selectedWindow === first.window)
        #expect(sent.filter { $0 == .key(tab, isDown: true) }.count == 2)
        #expect(sent.contains(.key(tab, isDown: false)))

        try press(0x1E, "]", [.command, .shift], in: first.window)
        await waitUntil("the next tab is shown") { tabGroup.selectedWindow === second.window }
        try press(0x21, "[", [.command, .shift], in: second.window)
        await waitUntil("the previous tab is shown") { tabGroup.selectedWindow === first.window }
    }

    @Test(arguments: [false, true])
    func screenshotOfATabbedSessionWindow(dark: Bool) async throws {
        let first = controller("Build Server", host: "build01.example.com", phase: .connecting)
        let second = controller(
            "Jump Host", host: "jump.example.com",
            phase: .disconnected(.connectionLost(RDPFailure(kind: .networkLost)))
        )
        defer { close(first, second) }
        for window in [first.window, second.window] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 720, height: 450))
        }
        tabGroup(first, second)
        let bytes = try await Screenshots.write(first.window, name: dark ? "session-tabs-dark" : "session-tabs")
        #expect(bytes > 0)
    }
}
