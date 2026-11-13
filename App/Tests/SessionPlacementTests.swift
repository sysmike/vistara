import AppKit
import Testing
import VistaraCore
@testable import Vistara

/// Where new sessions open: as tabs or windows, following the system's
/// "Prefer tabs" setting, with Option for the other (#100).
@Suite(.serialized)
@MainActor
struct SessionPlacementTests {
    private func coordinator(preferring preference: NSWindow.UserTabbingPreference) -> SessionCoordinator {
        let coordinator = SessionCoordinator(
            credentialStore: InMemoryCredentialStore(), trustStore: temporaryTrustStore()
        )
        coordinator.tabbingPreference = { preference }
        return coordinator
    }

    /// Nothing listens there, so each session ends at once and its window stays.
    private func nowhere(_ port: UInt16) -> SessionTarget {
        SessionTarget(name: "Nowhere \(port)", host: "127.0.0.1", port: port)
    }

    private func closeAll(_ coordinator: SessionCoordinator) {
        for controller in coordinator.sessionWindows {
            controller.window.close()
        }
    }

    @Test
    func theSystemSettingDecides() {
        #expect(SessionPlacement.preferred(by: .always, frontIsFullScreen: false) == .tab)
        #expect(SessionPlacement.preferred(by: .inFullScreen, frontIsFullScreen: true) == .tab)
        #expect(SessionPlacement.preferred(by: .inFullScreen, frontIsFullScreen: false) == .window)
        #expect(SessionPlacement.preferred(by: .manual, frontIsFullScreen: true) == .window)
        // No session window to join.
        #expect(SessionPlacement.preferred(by: .always, frontIsFullScreen: nil) == .window)
        #expect(SessionPlacement.tab.other == .window)
        #expect(SessionPlacement.tab.connectTitle == "Connect in New Tab")
        #expect(SessionPlacement.window.connectTitle == "Connect in New Window")
    }

    @Test
    func preferringTabsOpensATabOfTheSessionInFront() {
        let coordinator = coordinator(preferring: .always)
        defer { closeAll(coordinator) }
        let first = coordinator.open(nowhere(1))
        #expect(coordinator.defaultPlacement == .tab)
        let second = coordinator.open(nowhere(2))
        #expect(first.window.tabbedWindows?.contains(second.window) == true)
    }

    @Test
    func preferringWindowsOpensAWindow() {
        let coordinator = coordinator(preferring: .manual)
        defer { closeAll(coordinator) }
        let first = coordinator.open(nowhere(1))
        #expect(coordinator.defaultPlacement == .window)
        let second = coordinator.open(nowhere(2))
        #expect((first.window.tabbedWindows ?? []).isEmpty)
        #expect((second.window.tabbedWindows ?? []).isEmpty)
    }

    @Test
    func preferringTabsInFullScreenOpensAWindowOutsideIt() {
        let coordinator = coordinator(preferring: .inFullScreen)
        defer { closeAll(coordinator) }
        let first = coordinator.open(nowhere(1))
        #expect(!first.model.isFullScreen)
        #expect(coordinator.defaultPlacement == .window)
        let second = coordinator.open(nowhere(2))
        #expect((second.window.tabbedWindows ?? []).isEmpty)
    }

    /// Option's choice wins over the setting, both ways; AppKit's own
    /// automatic tabbing does not get a say.
    @Test
    func anExplicitPlacementWins() async {
        let coordinator = coordinator(preferring: .always)
        defer { closeAll(coordinator) }
        let first = coordinator.open(nowhere(1))
        await waitUntil("the first session window is key") { first.window.isKeyWindow }
        let window = coordinator.open(nowhere(2), placement: .window)
        #expect((window.window.tabbedWindows ?? []).isEmpty)

        let manual = self.coordinator(preferring: .manual)
        defer { closeAll(manual) }
        let alone = manual.open(nowhere(3))
        let tab = manual.open(nowhere(4), placement: .tab)
        #expect(alone.window.tabbedWindows?.contains(tab.window) == true)
    }

    @Test
    func connectingToABackgroundTabSelectsIt() async throws {
        let coordinator = coordinator(preferring: .always)
        defer { closeAll(coordinator) }
        let first = coordinator.open(nowhere(1))
        let second = coordinator.open(nowhere(2))
        let group = try #require(first.window.tabGroup)
        await waitUntil("the new tab is in front") { group.selectedWindow === second.window }

        let again = coordinator.open(nowhere(1))
        #expect(again === first)
        await waitUntil("the first tab is in front again") { group.selectedWindow === first.window }
        #expect(coordinator.sessionWindows.count == 2)
    }

    /// File > Connect has its Option alternate, with Option-Command-O.
    @Test
    func fileConnectHasTheOtherPlacementAsItsAlternate() throws {
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        file.update()
        let connect = try #require(file.items.first { $0.title == "Connect" })
        #expect(connect.keyEquivalent == "o")
        let index = try #require(file.items.firstIndex(of: connect))
        let alternate = file.items[index + 1]
        #expect(["Connect in New Tab", "Connect in New Window"].contains(alternate.title))
        #expect(alternate.keyEquivalent == "o")
        #expect(alternate.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option])
        #expect(alternate.isAlternate)
    }
}
