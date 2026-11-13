import AppKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// A session across all displays (docs/DESIGN.md, Multiple displays; #112).
/// CI has one display, so the displays are simulated and full screen is left
/// out; a Mac with two displays checks the rest (#6).
@Suite(.serialized)
@MainActor
struct SessionSpanTests {
    /// The main display, and one to its right whose top is 56 points lower.
    private static let twoDisplays = [
        DisplayLayout.Display(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), backingScale: 1, isMain: true),
        DisplayLayout.Display(frame: CGRect(x: 1920, y: 0, width: 1280, height: 1024), backingScale: 1, isMain: false)
    ]

    /// Runs `body` with simulated displays, then puts the real ones back.
    private func withDisplays(
        _ displays: [DisplayLayout.Display], separateSpaces: Bool = true, _ body: () async throws -> Void
    ) async rethrows {
        SessionWindowController.displays = { displays }
        SessionWindowController.displaysHaveSeparateSpaces = { separateSpaces }
        SessionWindowController.spansEnterFullScreen = false
        defer {
            SessionWindowController.displays = { MacDisplays.current() }
            SessionWindowController.displaysHaveSeparateSpaces = { NSScreen.screensHaveSeparateSpaces }
            SessionWindowController.spansEnterFullScreen = true
        }
        try await body()
    }

    private func coordinator() -> SessionCoordinator {
        SessionCoordinator(credentialStore: InMemoryCredentialStore(), trustStore: temporaryTrustStore())
    }

    private func spanning(_ port: UInt16) -> SessionTarget {
        var target = SessionTarget(name: "Nowhere \(port)", host: "127.0.0.1", port: port)
        target.usesAllDisplays = true
        return target
    }

    private func closeAll(_ coordinator: SessionCoordinator) {
        for controller in coordinator.sessionWindows { controller.window.close() }
    }

    @Test
    func aSessionOnAllDisplaysHasAWindowOnEach() async throws {
        try await withDisplays(Self.twoDisplays) {
            let coordinator = coordinator()
            defer { closeAll(coordinator) }
            let session = coordinator.open(spanning(1))
            let span = try #require(session.span)
            #expect(span.windows.count == 1)
            #expect(session.model.displayMonitors.count == 2)
            // One session in the menus; never tabs.
            #expect(span.windows.allSatisfy { $0.isExcludedFromWindowsMenu })
            #expect(!session.window.isExcludedFromWindowsMenu)
            #expect(([session.window] + span.windows).allSatisfy { $0.tabbingMode == .disallowed })
            #expect(coordinator.sessionWindows.count == 1)
        }
    }

    /// Each display shows its part of the one desktop, the bounding box of
    /// the monitors.
    @Test
    func eachDisplayShowsItsRegion() async throws {
        try await withDisplays(Self.twoDisplays) {
            let coordinator = coordinator()
            defer { closeAll(coordinator) }
            let model = coordinator.open(spanning(1)).model
            #expect(model.region(forMonitor: 0) == CGRect(x: 0, y: 0, width: 1920, height: 1080))
            #expect(model.region(forMonitor: 1) == CGRect(x: 1920, y: 56, width: 1280, height: 1024))
            #expect(model.remoteMonitors.map(\.isPrimary) == [true, false])
        }
    }

    @Test
    func closingAnyWindowEndsTheSession() async throws {
        try await withDisplays(Self.twoDisplays) {
            let coordinator = coordinator()
            defer { closeAll(coordinator) }
            let session = coordinator.open(spanning(1))
            let other = try #require(session.span?.windows.first)
            other.close()
            await waitUntil("every window of the session is closed") { coordinator.sessionWindows.isEmpty }
            #expect(!session.window.isVisible)
        }
    }

    /// Leaving full screen on any display: the other windows go, and the
    /// session goes on in its window, following it again.
    @Test
    func leavingTheSpanKeepsTheSessionInOneWindow() async throws {
        try await withDisplays(Self.twoDisplays) {
            let coordinator = coordinator()
            defer { closeAll(coordinator) }
            let session = coordinator.open(spanning(1))
            let other = try #require(session.span?.windows.first)
            session.endSpan()
            #expect(session.span == nil)
            #expect(!other.isVisible)
            #expect(session.window.isVisible)
            #expect(session.model.displayMonitors.isEmpty)
            #expect(session.model.region(forMonitor: 0) == nil)
            #expect(coordinator.sessionWindows.count == 1)
        }
    }

    @Test
    func withoutSeparateSpacesOrASecondDisplayTheSessionStaysInOneWindow() async throws {
        try await withDisplays(Self.twoDisplays, separateSpaces: false) {
            let coordinator = coordinator()
            defer { closeAll(coordinator) }
            #expect(coordinator.open(spanning(1)).span == nil)
        }
        try await withDisplays(Array(Self.twoDisplays.prefix(1))) {
            let coordinator = coordinator()
            defer { closeAll(coordinator) }
            #expect(coordinator.open(spanning(2)).span == nil)
        }
    }

    @Test
    func aSessionAcrossDisplaysNeverTakesATab() async throws {
        try await withDisplays(Self.twoDisplays) {
            let coordinator = coordinator()
            coordinator.tabbingPreference = { .always }
            defer { closeAll(coordinator) }
            let spanningSession = coordinator.open(spanning(1))
            let other = coordinator.open(SessionTarget(name: "Nowhere 2", host: "127.0.0.1", port: 2))
            #expect((spanningSession.window.tabbedWindows ?? []).isEmpty)
            #expect((other.window.tabbedWindows ?? []).isEmpty)
        }
    }
}
