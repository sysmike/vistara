import AppKit
import Foundation
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// The Mac's displays as a RemoteApp session's desktop, and how a program
/// window follows a drag (#155).
@Suite
@MainActor
struct RemoteAppSpaceTests {
    /// A 1440x900 main display and, to its left and a little higher, a
    /// 1920x1080 one, at twice the density.
    private let space = RemoteAppSpace(
        displays: [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 100, width: 1920, height: 1080)],
        visibleMain: CGRect(x: 0, y: 70, width: 1440, height: 800), usesHiDPI: true, backingScale: 2
    )

    @Test func eachDisplayIsAMonitorAtOneDensity() {
        #expect(space.scale == 2)
        let monitors = space.monitors
        #expect(monitors.count == 2)
        #expect(monitors[0] == RDPMonitor(x: 0, y: 0, width: 2880, height: 1800, isPrimary: true, scalePercent: 200))
        // Its top is 280 points above the main display's top.
        #expect(monitors[1] == RDPMonitor(
            x: -3840, y: -560, width: 3840, height: 2160, isPrimary: false, scalePercent: 200
        ))
        let box = space.boundingBox
        #expect(box.x == -3840 && box.y == -560 && box.width == 6720 && box.height == 2360)
    }

    @Test func aRectangleGoesBothWays() {
        let remote = RDPRect(x: 200, y: 160, width: 800, height: 600)
        let screen = space.screenRect(for: remote)
        #expect(screen == CGRect(x: 100, y: 520, width: 400, height: 300))
        #expect(space.remoteRect(for: screen) == remote)
        // On the other display, left of the main one.
        let left = RDPRect(x: -2000, y: -100, width: 400, height: 200)
        #expect(space.remoteRect(for: space.screenRect(for: left)) == left)
    }

    @Test func theFramebufferStartsAtTheBoundingBox() {
        #expect(space.framebufferRegion(for: RDPRect(x: 200, y: 160, width: 800, height: 600))
            == CGRect(x: 4040, y: 720, width: 800, height: 600))
        let point = space.framebufferPoint(for: CGPoint(x: 100, y: 820))
        #expect(point.x == 4040 && point.y == 720)
    }

    @Test func aMaximizedWindowLeavesTheMenuBarAndTheDock() {
        #expect(space.workArea == RDPRect(x: 0, y: 60, width: 2880, height: 1600))
    }

    @Test func aDesktopTooLargeForRDPHasFewerPixels() {
        let wide = RemoteAppSpace(
            displays: [CGRect(x: 0, y: 0, width: 5120, height: 2880)], visibleMain: .zero, usesHiDPI: true,
            backingScale: 2
        )
        #expect(wide.scale == 1)
    }

    @Test func aDragMovesTheWindowOrItsEdgesWithinTheLimits() {
        let start = CGPoint(x: 150, y: 590)
        let frame = CGRect(x: 100, y: 300, width: 400, height: 300)
        let minimum = CGSize(width: 200, height: 150)
        let huge = CGSize(width: 10000, height: 10000)
        func dragged(_ kind: RDPMoveSizeKind, by delta: CGPoint) -> CGRect {
            ProgramWindow.frame(
                for: ProgramWindow.LocalDrag(kind: kind, start: start, startFrame: frame),
                pointer: CGPoint(x: start.x + delta.x, y: start.y + delta.y), minSize: minimum, maxSize: huge
            )
        }
        #expect(dragged(.move, by: CGPoint(x: 60, y: -40)) == CGRect(x: 160, y: 260, width: 400, height: 300))
        #expect(dragged(.right, by: CGPoint(x: 50, y: 0)) == CGRect(x: 100, y: 300, width: 450, height: 300))
        #expect(dragged(.left, by: CGPoint(x: -20, y: 0)) == CGRect(x: 80, y: 300, width: 420, height: 300))
        // The remote top is the Mac's larger y.
        #expect(dragged(.top, by: CGPoint(x: 0, y: 30)) == CGRect(x: 100, y: 300, width: 400, height: 330))
        #expect(dragged(.bottomRight, by: CGPoint(x: -500, y: 500)) == CGRect(x: 100, y: 450, width: 200, height: 150))
        #expect(dragged(.keyboardMove, by: CGPoint(x: 60, y: 60)) == frame)
    }
}

/// Program windows against the test server's RemoteApp host
/// (scripts/test-server/sample-screen.patch).
@Suite(.serialized)
@MainActor
struct ProgramWindowTests {
    private static func railLines(after before: Int = 0) -> [String] {
        guard let path = ProcessInfo.processInfo.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").dropFirst(before).compactMap { line in
            line.range(of: "vistara-rail ").map { String(line[$0.upperBound...]) }
        }
    }

    private static var lineCount: Int {
        guard let path = ProcessInfo.processInfo.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return 0 }
        return log.split(separator: "\n").count
    }

    private struct Opened {
        let coordinator: SessionCoordinator
        let controller: SessionWindowController
        let programs: ProgramWindows
    }

    /// Opens the test server's notepad and waits for its window and popup.
    private func openNotepad() async throws -> Opened {
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
        await waitUntil("the program's window and its popup are shown") {
            model.programs?.controllers[0x101]?.window.isVisible == true
        }
        return Opened(coordinator: coordinator, controller: controller, programs: try #require(model.programs))
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func theProgramsWindowsAreMacWindowsWhereTheServerPutsThem() async throws {
        let opened = try await openNotepad()
        let (coordinator, controller, programs) = (opened.coordinator, opened.controller, opened.programs)
        let notepad = try #require(programs.controllers[0x100])
        let popup = try #require(programs.controllers[0x101])

        #expect(notepad.window.frame == programs.space.screenRect(for: RDPRect(x: 100, y: 80, width: 400, height: 300)))
        #expect(notepad.window.title == "Vistara Notepad")
        #expect(notepad.window.miniwindowImage != nil)
        #expect(notepad.window.takesKeyboard)
        #expect(notepad.window.styleMask.contains(.titled) == false)
        // The popup is above the window it belongs to, and never takes the keyboard.
        #expect(popup.window.parent === notepad.window)
        #expect(!popup.window.takesKeyboard)
        // The session window steps aside while the program runs.
        #expect(!controller.window.isVisible)
        // Typing goes to the program's window.
        await waitUntil("the notepad window has the keyboard") { notepad.window.isKeyWindow }
        #expect(notepad.window.firstResponder === notepad.view)
        await waitUntil("the drawing has begun") { notepad.view.drawCount > 0 }

        coordinator.disconnect(controller.model)
        await waitUntil("the session has ended") { !controller.model.isLive }
        #expect(!notepad.window.isVisible)
        #expect(controller.model.programs == nil)
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func aDragOnTheTitleBarMovesTheWindowAndTheServerHearsOfIt() async throws {
        let before = Self.lineCount
        let opened = try await openNotepad()
        let (coordinator, controller, programs) = (opened.coordinator, opened.controller, opened.programs)
        let notepad = try #require(programs.controllers[0x100])
        // Becoming key activates it, and the server answers as if its title bar were pressed.
        await waitUntil("the Mac follows the drag") { notepad.window.localDrag != nil }
        let start = try #require(notepad.window.localDrag?.start)
        let frame = notepad.window.frame

        let end = CGPoint(x: start.x + 60, y: start.y - 40)
        for (type, point) in [(NSEvent.EventType.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: notepad.window.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: notepad.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
            notepad.window.sendEvent(event)
        }

        let moved = frame.offsetBy(dx: 60, dy: -40)
        #expect(notepad.window.frame == moved)
        let remote = programs.space.remoteRect(for: moved)
        let line = "window-move id=0x100 left=\(remote.x) top=\(remote.y) "
            + "right=\(remote.x + remote.width) bottom=\(remote.y + remote.height)"
        await waitUntil("the server heard of the move") { Self.railLines(after: before).contains(line) }
        // The server's answer puts the window where the Mac did.
        await waitUntil("the window stays where it was dragged") {
            notepad.remote.frame == remote && notepad.window.frame == moved
        }

        coordinator.disconnect(controller.model)
        await waitUntil("the session has ended") { !controller.model.isLive }
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer))
    func closingTheLastWindowEndsTheSession() async throws {
        let before = Self.lineCount
        let opened = try await openNotepad()
        let (coordinator, controller, programs) = (opened.coordinator, opened.controller, opened.programs)
        let notepad = try #require(programs.controllers[0x100])

        // File > Close asks the program, which deletes the window and its popup.
        notepad.window.performClose(nil)
        await waitUntil("the program closed its windows") { programs.controllers.isEmpty }
        #expect(Self.railLines(after: before).contains("syscommand id=0x100 command=0xf060"))
        #expect(!notepad.window.isVisible)

        await waitUntil("the session ended after its last window", within: .seconds(15)) {
            !controller.model.isLive
        }
        #expect(coordinator.liveSessionCount == 0)
    }

    @Test(.enabled(if: TestServer.isFreeRDPTestServer), arguments: [false, true])
    func screenshots(dark: Bool) async throws {
        let opened = try await openNotepad()
        let (coordinator, controller, programs) = (opened.coordinator, opened.controller, opened.programs)
        let notepad = try #require(programs.controllers[0x100])
        // A Mac window beside the program's, in the appearance asked for.
        let mac = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        mac.isReleasedWhenClosed = false
        mac.title = "Notes"
        mac.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let program = notepad.window.frame
        mac.setFrameTopLeftPoint(CGPoint(x: program.maxX + 20, y: program.maxY))
        mac.orderFront(nil)
        defer { mac.close() }
        try await Task.sleep(for: .milliseconds(600))

        let main = NSScreen.screens[0].frame
        let area = program.union(mac.frame).insetBy(dx: -30, dy: -30)
        let rect = CGRect(x: area.minX - main.minX, y: main.maxY - area.maxY, width: area.width, height: area.height)
        try await Screenshots.write(screenRect: rect, name: dark ? "program-window-dark" : "program-window")

        coordinator.disconnect(controller.model)
        await waitUntil("the session has ended") { !controller.model.isLive }
    }
}
