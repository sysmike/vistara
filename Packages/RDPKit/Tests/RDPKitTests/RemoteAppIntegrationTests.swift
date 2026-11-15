import Foundation
import Testing

@testable import RDPKit

/// RemoteApp against the test server, which plays a RemoteApp host
/// (scripts/test-server/sample-screen.patch): "||vistara-notepad" opens window
/// 0x100 with an icon and a popup 0x101 owned by it, "||vistara-calc" opens
/// window 0x200, and anything else is not published.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(2)))
struct RemoteAppIntegrationTests {
    static let notepad = RDPProgram(path: "||vistara-notepad")

    /// What a RemoteApp session reported so far.
    private struct Reported {
        var windows: [UInt32: RDPRemoteWindow] = [:]
        var deleted: Set<UInt32> = []
        var events: [RDPRemoteAppEvent] = []
    }

    private static func railLines(after before: Int) -> [String] {
        FileClipboardIntegrationTests.serverLog().dropFirst(before).compactMap { line in
            line.range(of: "vistara-rail ").map { String(line[$0.upperBound...]) }
        }
    }

    private static func connect(_ program: RDPProgram) throws -> SessionHandle {
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.program = program
        try #require(handle.connect(to: target) { _ in true } == .connected)
        return handle
    }

    /// Polls until `done` holds or `seconds` pass.
    private static func pump(
        _ handle: SessionHandle, into reported: inout Reported, seconds: TimeInterval = 15,
        until done: (Reported) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(reported), Date() < deadline, handle.poll(timeoutMilliseconds: 100) {
            for window in handle.takeRemoteWindows() {
                if window.isDeleted { reported.deleted.insert(window.id) }
                reported.windows[window.id] = window
            }
            reported.events += handle.takeRemoteAppEvents()
        }
    }

    private static func waitForLine(after before: Int, _ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if railLines(after: before).contains(where: matches) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    @Test func theProgramStartsAndItsWindowsAreReported() throws {
        let before = FileClipboardIntegrationTests.serverLog().count
        let handle = try Self.connect(Self.notepad)
        defer { handle.disconnect() }

        var reported = Reported()
        Self.pump(handle, into: &reported) { reported in
            reported.windows[0x101] != nil && reported.windows[0x100]?.icon != nil
                && reported.events.contains { if case .sizeLimits = $0 { true } else { false } }
        }

        #expect(reported.events.first == .programStarted)
        let window = try #require(reported.windows[0x100])
        #expect(window.title == "Vistara Notepad")
        #expect(window.frame == RDPRect(x: 100, y: 80, width: 400, height: 300))
        #expect(window.visibleRegion == [window.frame])
        #expect(window.hasTitleBar)
        #expect(window.showState == .shown)
        let icon = try #require(window.icon)
        #expect(icon.width == 16 && icon.height == 16)
        #expect(Array(icon.pixels.prefix(4)) == [0x00, 0x80, 0xFF, 0xFF])
        let popup = try #require(reported.windows[0x101])
        #expect(popup.ownerID == 0x100)
        #expect(popup.isPopup)
        #expect(reported.events.contains(.sizeLimits(windowID: 0x100, RDPWindowSizeLimits(
            maximized: RDPRect(x: 0, y: 0, width: 1024, height: 728),
            minimumWidth: 200, minimumHeight: 150, maximumWidth: 1024, maximumHeight: 768
        ))))

        let lines = Self.railLines(after: before)
        #expect(lines.contains("exec program=||vistara-notepad arguments="))
        #expect(lines.contains { $0.hasPrefix("client-status ") })
        #expect(lines.contains("work-area left=0 top=0 right=1024 bottom=768"))
    }

    @Test func activatingMovingMinimizingAndClosingReachTheServer() throws {
        let before = FileClipboardIntegrationTests.serverLog().count
        let handle = try Self.connect(Self.notepad)
        defer { handle.disconnect() }
        var reported = Reported()
        Self.pump(handle, into: &reported) { $0.windows[0x101] != nil }

        // The first activation makes the server pretend its title bar was
        // pressed; the move that follows ends the drag.
        #expect(handle.send(.remoteApp(.activate(windowID: 0x100, isActive: true))))
        Self.pump(handle, into: &reported) { reported in
            reported.events.contains { if case .moveSizeBegan = $0 { true } else { false } }
        }
        #expect(reported.events.contains(.moveSizeBegan(windowID: 0x100, kind: .move, x: 150, y: 90)))

        let frame = RDPRect(x: 300, y: 200, width: 400, height: 300)
        #expect(handle.send(.remoteApp(.move(windowID: 0x100, frame: frame))))
        Self.pump(handle, into: &reported) { reported in
            reported.windows[0x100]?.frame == frame
                && reported.events.contains { if case .moveSizeEnded = $0 { true } else { false } }
        }
        #expect(reported.windows[0x100]?.frame == frame)
        #expect(reported.events.contains(.moveSizeEnded(windowID: 0x100, x: 300, y: 200)))

        #expect(handle.send(.remoteApp(.command(.minimize, windowID: 0x100))))
        #expect(handle.send(.remoteApp(.workArea(RDPRect(x: 0, y: 25, width: 1024, height: 675)))))
        #expect(handle.send(.remoteApp(.command(.close, windowID: 0x100))))
        Self.pump(handle, into: &reported) { $0.deleted.isSuperset(of: [0x100, 0x101]) }
        #expect(reported.deleted.isSuperset(of: [0x100, 0x101]))

        let lines = Self.railLines(after: before)
        #expect(lines.contains("activate id=0x100 enabled=1"))
        #expect(lines.contains("window-move id=0x100 left=300 top=200 right=700 bottom=500"))
        #expect(lines.contains("syscommand id=0x100 command=0xf020"))
        #expect(lines.contains("work-area left=0 top=25 right=1024 bottom=700"))
        #expect(lines.contains("syscommand id=0x100 command=0xf060"))
    }

    @Test func aSecondProgramStartsInTheSameSession() throws {
        let before = FileClipboardIntegrationTests.serverLog().count
        let handle = try Self.connect(Self.notepad)
        defer { handle.disconnect() }
        var reported = Reported()
        Self.pump(handle, into: &reported) { $0.windows[0x100] != nil }

        #expect(handle.send(.remoteApp(.start(RDPProgram(path: "||vistara-calc", arguments: "/scientific")))))
        // The answer to the start comes on the RAIL channel, the window as an
        // update: either may be first.
        Self.pump(handle, into: &reported) { reported in
            reported.windows[0x200] != nil && reported.events.filter { $0 == .programStarted }.count == 2
        }

        #expect(reported.windows[0x200]?.title == "Vistara Calculator")
        #expect(reported.events.filter { $0 == .programStarted }.count == 2)
        let lines = Self.railLines(after: before)
        #expect(lines.contains("exec program=||vistara-calc arguments=/scientific"))
        #expect(lines.filter { $0.hasPrefix("handshake ") }.count == 1)
    }

    @Test func aProgramTheServerDoesNotPublishIsSaidSo() throws {
        let handle = try Self.connect(RDPProgram(path: "||not-published"))
        defer { handle.disconnect() }
        var reported = Reported()
        Self.pump(handle, into: &reported) { !$0.events.isEmpty }

        #expect(reported.events == [.programFailed(.notPublished)])
        #expect(reported.windows.isEmpty)
    }

    @Test func aDesktopSessionLoadsNoRemoteAppChannel() throws {
        let before = FileClipboardIntegrationTests.serverLog().count
        let handle = try #require(SessionHandle())
        #expect(handle.connect(to: TestHost.target()) { _ in true } == .connected)
        defer { handle.disconnect() }
        var reported = Reported()
        Self.pump(handle, into: &reported, seconds: 3) { _ in false }

        #expect(reported.windows.isEmpty && reported.events.isEmpty)
        #expect(!handle.send(.remoteApp(.start(Self.notepad))))
        #expect(!Self.railLines(after: before).contains("opened"))
    }

    @Test func aSessionSaysWhenTheLastWindowHasGone() async throws {
        var configuration = TestHost.configuration
        configuration.program = Self.notepad
        let session = RDPSession(configuration: configuration, delegate: TestHost.delegate())
        session.start()
        var states = session.states.makeAsyncIterator()
        while let state = await states.next() {
            if case .connected = state { break }
        }

        var windows = session.remoteWindows.makeAsyncIterator()
        while let batch = await windows.next(), !batch.contains(where: { $0.id == 0x101 }) {}
        session.send([.remoteApp(.command(.close, windowID: 0x100))])
        let closedAt = ContinuousClock.now

        var events = session.remoteAppEvents.makeAsyncIterator()
        var sawLastWindow = false
        while let event = await events.next() {
            if event == .lastWindowClosed {
                sawLastWindow = true
                break
            }
        }
        #expect(sawLastWindow)
        #expect(ContinuousClock.now - closedAt >= RDPSession.lastWindowGrace)
        session.disconnect()
        while await states.next() != nil {}
    }
}
