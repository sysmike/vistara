import AppKit
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// A session across displays follows displays added, removed, or rearranged
/// (docs/DESIGN.md, Multiple displays; #114). The displays are simulated; CI
/// has one.
@Suite(.serialized)
@MainActor
struct DisplayChangeTests {
    private static func display(_ x: CGFloat, main: Bool = false) -> DisplayLayout.Display {
        DisplayLayout.Display(frame: CGRect(x: x, y: 0, width: 1920, height: 1080), backingScale: 1, isMain: main)
    }

    private static let one = [display(0, main: true)]
    private static let two = one + [display(1920)]
    private static let three = two + [display(3840)]

    /// The displays the session sees; tests change them.
    private final class Displays {
        var current: [DisplayLayout.Display]
        init(_ current: [DisplayLayout.Display]) { self.current = current }
    }

    /// A connected session meant for all displays, its windows, and a way to
    /// change the displays.
    private func withSession(
        on start: [DisplayLayout.Display], _ body: (SessionWindowController, Displays) async throws -> Void
    ) async rethrows {
        let displays = Displays(start)
        SessionWindowController.displays = { displays.current }
        SessionWindowController.displaysHaveSeparateSpaces = { true }
        SessionWindowController.spansEnterFullScreen = false
        SessionWindowController.displayChangeDelay = .milliseconds(20)
        var target = SessionTarget(name: "Build Server", host: "127.0.0.1", port: 1)
        target.usesAllDisplays = true
        let model = SessionModel(target: target, credentialStore: InMemoryCredentialStore(), phase: .connected)
        let controller = SessionWindowController(model: model)
        controller.show()
        defer {
            controller.window.close()
            SessionWindowController.displays = { MacDisplays.current() }
            SessionWindowController.displaysHaveSeparateSpaces = { NSScreen.screensHaveSeparateSpaces }
            SessionWindowController.spansEnterFullScreen = true
            SessionWindowController.displayChangeDelay = .milliseconds(250)
        }
        try await body(controller, displays)
    }

    private func change(_ displays: Displays, to next: [DisplayLayout.Display]) {
        displays.current = next
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    }

    @Test
    func aDisplayAddedGetsAWindowAndTheLayoutFollows() async throws {
        try await withSession(on: Self.two) { session, displays in
            #expect(session.span?.windows.count == 1)
            change(displays, to: Self.three)
            await waitUntil("a window on the new display") { session.span?.windows.count == 2 }
            #expect(session.model.displayMonitors.count == 3)
            #expect(session.model.requestedLayout == session.model.remoteMonitors)
            #expect(session.model.requestedLayout.count == 3)
        }
    }

    /// Several changes in a row are followed once, after they rest.
    @Test
    func aBurstOfChangesIsFollowedOnceItRests() async throws {
        try await withSession(on: Self.two) { session, displays in
            let before = try #require(session.span)
            change(displays, to: Self.three)
            change(displays, to: Self.one)
            change(displays, to: Self.three)
            #expect(session.span === before)
            await waitUntil("the last arrangement is followed") { session.model.displayMonitors.count == 3 }
            #expect(session.span?.windows.count == 2)
        }
    }

    @Test
    func anUnchangedArrangementChangesNothing() async throws {
        try await withSession(on: Self.two) { session, displays in
            let before = try #require(session.span)
            change(displays, to: Self.two)
            try await Task.sleep(for: .milliseconds(200))
            #expect(session.span === before)
        }
    }

    /// Left with one display, the session goes on in its window; a second
    /// display brings the span back.
    @Test
    func downToOneDisplayAndBack() async throws {
        try await withSession(on: Self.two) { session, displays in
            change(displays, to: Self.one)
            await waitUntil("the span gives way") { session.span == nil }
            #expect(session.model.displayMonitors.isEmpty)
            #expect(session.model.requestedLayout.isEmpty)
            #expect(session.window.isVisible)

            change(displays, to: Self.two)
            await waitUntil("the span comes back") { session.span?.windows.count == 1 }
            #expect(session.model.displayMonitors.count == 2)
            #expect(session.model.requestedLayout.count == 2)
        }
    }

    /// Leaving full screen is the user's choice: a display added afterwards
    /// does not span the session again.
    @Test
    func afterTheUserLeavesTheSpanItStaysInOneWindow() async throws {
        try await withSession(on: Self.two) { session, displays in
            session.endSpan()
            change(displays, to: Self.three)
            try await Task.sleep(for: .milliseconds(200))
            #expect(session.span == nil)
            #expect(session.model.displayMonitors.isEmpty)
        }
    }
}
