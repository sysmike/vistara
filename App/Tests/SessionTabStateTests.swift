import AppKit
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// Each tab shows how its session is doing, and VoiceOver hears it even from
/// a tab in the background (#102).
@Suite(.serialized)
@MainActor
struct SessionTabStateTests {
    private static let lost = RDPDisconnectReason.connectionLost(RDPFailure(kind: .networkLost))

    private func controller(_ name: String, host: String, phase: SessionModel.Phase) -> SessionWindowController {
        let target = SessionTarget(name: name, host: host, port: 3389)
        let model = SessionModel(target: target, credentialStore: InMemoryCredentialStore(), phase: phase)
        return SessionWindowController(model: model)
    }

    private func close(_ controllers: [SessionWindowController]) {
        for controller in controllers where controller.window.isVisible {
            controller.window.close()
        }
    }

    @Test
    func eachPhaseHasItsState() {
        let model = SessionModel(
            target: SessionTarget(name: "Build Server", host: "build01", port: 3389),
            credentialStore: InMemoryCredentialStore(), phase: .connecting
        )
        #expect(SessionTabState.of(model) == .progress("Connecting"))
        model.phase = .connected
        #expect(SessionTabState.of(model) == SessionTabState.none)
        model.phase = .reconnecting(Reconnection(lost: Self.lost))
        #expect(SessionTabState.of(model) == .progress("Reconnecting"))
        model.phase = .disconnected(Self.lost)
        #expect(SessionTabState.of(model) == .ended(model.disconnectMessage(for: Self.lost).title))
    }

    /// Shapes and labels, not colours: a spinner, a symbol, or nothing, each
    /// with what VoiceOver reads.
    @Test
    func theTabsAccessoryFollowsTheSession() async throws {
        let session = controller("Build Server", host: "build01", phase: .connecting)
        defer { close([session]) }
        let progress = try #require(session.window.tab.accessoryView as? NSProgressIndicator)
        #expect(progress.accessibilityLabel() == "Connecting")

        session.model.phase = .connected
        await waitUntil("the accessory is gone") { session.window.tab.accessoryView == nil }

        session.model.phase = .disconnected(Self.lost)
        await waitUntil("the accessory says it ended") { session.window.tab.accessoryView is NSImageView }
        let ended = try #require(session.window.tab.accessoryView as? NSImageView)
        #expect(ended.accessibilityLabel() == session.model.disconnectMessage(for: Self.lost).title)
        #expect(ended.toolTip == ended.accessibilityLabel())
    }

    /// A tab in the background is announced with its connection's name; the
    /// one in front as before.
    @Test
    func aBackgroundTabIsAnnouncedWithItsName() async {
        var heard: [String] = []
        SessionAnnouncement.observer = { heard.append($0) }
        defer { SessionAnnouncement.observer = nil }
        let front = controller("Build Server", host: "build01", phase: .connecting)
        let back = controller("Jump Host", host: "jump", phase: .connecting)
        defer { close([front, back]) }
        NSApp.activate(ignoringOtherApps: true)
        front.show()
        front.window.addTabbedWindow(back.window, ordered: .above)
        front.window.makeKeyAndOrderFront(nil)
        await waitUntil("the first tab is in front") { front.window.tabGroup?.selectedWindow === front.window }

        // "Connection cancelled" does not name the connection by itself.
        back.model.phase = .disconnected(.userRequested)
        await waitUntil("the background tab is announced") { !heard.isEmpty }
        #expect(heard == ["Jump Host: Connection cancelled"])

        front.model.phase = .disconnected(.userRequested)
        await waitUntil("the front tab is announced") { heard.count == 2 }
        #expect(heard.last == "Connection cancelled")
    }

    @Test(arguments: [false, true])
    func screenshotOfTabsInEachState(dark: Bool) async throws {
        let connected = controller("Build Server", host: "build01.example.com", phase: .connected)
        let reconnecting = controller(
            "Jump Host", host: "jump.example.com", phase: .reconnecting(Reconnection(lost: Self.lost))
        )
        let ended = controller("Finance VM", host: "10.0.4.17", phase: .disconnected(Self.lost))
        let all = [connected, reconnecting, ended]
        defer { close(all) }
        for session in all {
            session.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            session.window.setContentSize(NSSize(width: 720, height: 450))
        }
        NSApp.activate(ignoringOtherApps: true)
        ended.show()
        ended.window.addTabbedWindow(connected.window, ordered: .below)
        ended.window.addTabbedWindow(reconnecting.window, ordered: .below)
        ended.window.makeKeyAndOrderFront(nil)
        let bytes = try await Screenshots.write(ended.window, name: dark ? "tab-states-dark" : "tab-states")
        #expect(bytes > 0)
    }
}
