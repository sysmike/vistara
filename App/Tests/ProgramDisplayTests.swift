import AppKit
import Foundation
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// Program windows when the Mac's displays change while a program runs (#161).
@Suite
@MainActor
struct ProgramPlacementTests {
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visibleMain = CGRect(x: 0, y: 70, width: 1440, height: 805)
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func aWindowWhoseTitleBarIsStillOnADisplayStays() {
        let window = CGRect(x: 1300, y: 400, width: 400, height: 300)
        // Its title bar reaches onto the main display.
        #expect(RemoteAppSpace.placement(of: window, on: [main], visibleMain: visibleMain) == window)
        let onRight = CGRect(x: 2000, y: 200, width: 400, height: 300)
        #expect(RemoteAppSpace.placement(of: onRight, on: [main, right], visibleMain: visibleMain) == onRight)
    }

    @Test func aWindowWhoseDisplayWentAwayComesToTheMainOne() {
        let onRight = CGRect(x: 2000, y: 200, width: 400, height: 300)
        #expect(RemoteAppSpace.placement(of: onRight, on: [main], visibleMain: visibleMain)
            == CGRect(x: 20, y: 555, width: 400, height: 300))
        // As large as fits.
        let huge = CGRect(x: 2000, y: 0, width: 1900, height: 1000)
        #expect(RemoteAppSpace.placement(of: huge, on: [main], visibleMain: visibleMain)
            == CGRect(x: 20, y: 70, width: 1440, height: 805))
    }

    @Test func aWindowOnTheMainDisplayKeepsItsRemotePlaceWhenADisplayIsAdded() {
        let before = RemoteAppSpace(displays: [main], visibleMain: visibleMain, usesHiDPI: true, backingScale: 2)
        let after = RemoteAppSpace(
            displays: [main, right], visibleMain: visibleMain, usesHiDPI: true, backingScale: 2
        )
        let window = CGRect(x: 100, y: 300, width: 400, height: 300)
        #expect(before.remoteRect(for: window) == after.remoteRect(for: window))
        #expect(after.monitors.count == 2)
        #expect(after.boundingBox.width == (1440 + 1920) * 2)
    }

    @Test func simulatedDisplaysMakeTheSpace() {
        let displays = [
            DisplayLayout.Display(frame: right, backingScale: 1, isMain: false),
            DisplayLayout.Display(frame: main, backingScale: 2, isMain: true)
        ]
        let space = RemoteAppSpace.current(displays: displays, usesHiDPI: true)
        // The main display first, at its density.
        #expect(space.displays == [main, right])
        #expect(space.scale == 2)
    }
}

/// A display added under a running program, against the test server.
@Suite(.serialized)
@MainActor
struct ProgramDisplayTests {
    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func addingADisplayAsksForTheNewLayoutAndKeepsTheWindows() async throws {
        let server = try #require(TestServer.current)
        let coordinator = SessionCoordinator(
            credentialStore: try server.storeWithCredentials(), trustStore: temporaryTrustStore()
        )
        var target = server.target
        target.program = Connection.Program(opens: .program, path: "||vistara-notepad")
        let controller = coordinator.open(target)
        let model = controller.model
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the program's window is shown") {
            model.programs?.controllers[0x100]?.window.isVisible == true
        }
        let programs = try #require(model.programs)
        let notepad = try #require(programs.controllers[0x100])
        let frame = notepad.window.frame
        let remote = notepad.remote.frame

        // A second display to the right of the real one.
        let real = try #require(MacDisplays.current().first)
        let added = DisplayLayout.Display(
            frame: CGRect(x: real.frame.maxX, y: 0, width: 800, height: 600), backingScale: real.backingScale,
            isMain: false
        )
        SessionWindowController.displays = { [real, added] }
        ProgramWindows.displayChangeDelay = .milliseconds(50)
        defer {
            SessionWindowController.displays = { MacDisplays.current() }
            ProgramWindows.displayChangeDelay = .milliseconds(500)
        }
        programs.displaysMayHaveChanged()

        await waitUntil("the remote desktop takes the new layout", within: .seconds(15)) {
            programs.space.displays.count == 2
        }
        let box = programs.space.boundingBox
        #expect(model.framebuffer?.size.width == box.width && model.framebuffer?.size.height == box.height)
        // The window stays where it was, on the Mac and remotely.
        #expect(notepad.window.frame == frame)
        #expect(!notepad.holdsPlace)
        #expect(programs.space.remoteRect(for: notepad.window.frame) == remote)
        #expect(notepad.view.region == programs.space.framebufferRegion(for: notepad.remote.frame))

        coordinator.disconnect(model)
        await waitUntil("the session has ended") { !model.isLive }
    }
}
