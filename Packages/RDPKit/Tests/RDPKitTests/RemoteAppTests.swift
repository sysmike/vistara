import Foundation
import Testing

@testable import RDPKit

/// Window orders as the shim keeps them, and what RDPKit makes of them (#154).
@Suite
struct RemoteAppWindowTests {
    private let notepad = RDPRemoteWindow(
        id: 0x100, style: 0x10CF_0000, extendedStyle: 0x0004_0000, showState: .shown, title: "Notepad",
        frame: RDPRect(x: 100, y: 80, width: 400, height: 300)
    )
    private let all: RemoteAppWindows.Fields = [.new, .owner, .style, .show, .title, .offset, .size]

    @Test func aNewWindowIsReportedWithEveryField() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(notepad, fields: all)

        let taken = windows.take()
        // With no visible parts sent, all of the frame shows.
        var expected = notepad
        expected.visibleRegion = [notepad.frame]
        #expect(taken == [expected])
        #expect(taken.first?.hasTitleBar == true)
        #expect(taken.first?.isPopup == false)
        // Nothing changed since.
        #expect(windows.take().isEmpty)
    }

    @Test func anOrderWithSomeFieldsLeavesTheOthers() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(notepad, fields: all)
        _ = windows.take()

        var renamed = notepad
        renamed.title = "Notepad – Notes.txt"
        renamed.frame = RDPRect(x: 0, y: 0, width: 1, height: 1)
        renamed.style = 0
        windows.apply(renamed, fields: [.title])

        let taken = try #require(windows.take().first)
        #expect(taken.title == "Notepad – Notes.txt")
        #expect(taken.frame == notepad.frame)
        #expect(taken.style == notepad.style)
    }

    @Test func aMoveChangesOnlyThePlace() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(notepad, fields: all)
        _ = windows.take()

        var moved = notepad
        moved.frame = RDPRect(x: 300, y: 200, width: 500, height: 350)
        moved.title = "ignored"
        windows.apply(moved, fields: [.offset, .size])

        let taken = try #require(windows.take().first)
        #expect(taken.frame == moved.frame)
        #expect(taken.title == "Notepad")
    }

    @Test func theVisiblePartsAreMovedToTheDesktop() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(
            notepad, fields: all.union([.visibleOffset, .visibility]), visibleOffset: (100, 80),
            visible: [RDPRect(x: 0, y: 0, width: 400, height: 20), RDPRect(x: 10, y: 20, width: 380, height: 280)]
        )
        let taken = try #require(windows.take().first)
        #expect(taken.visibleRegion == [
            RDPRect(x: 100, y: 80, width: 400, height: 20), RDPRect(x: 110, y: 100, width: 380, height: 280)
        ])
    }

    @Test func aPopupHasItsOwner() throws {
        let windows = try #require(RemoteAppWindows())
        let menu = RDPRemoteWindow(
            id: 0x101, ownerID: 0x100, style: 0x9000_0000, frame: RDPRect(x: 140, y: 140, width: 160, height: 100)
        )
        windows.apply(menu, fields: all)
        let taken = try #require(windows.take().first)
        #expect(taken.ownerID == 0x100)
        #expect(taken.isPopup)
        #expect(!taken.hasTitleBar)
    }

    @Test func aDeletedWindowIsToldOnceThenForgotten() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(notepad, fields: all)
        _ = windows.take()
        windows.delete(0x100)

        let taken = windows.take()
        #expect(taken.map(\.id) == [0x100])
        #expect(taken.first?.isDeleted == true)
        #expect(taken.first?.title == "Notepad")
        #expect(windows.take().isEmpty)
        // An order for it now is a new window, with nothing from before.
        windows.apply(notepad.with { $0.title = "" }, fields: [.title])
        #expect(windows.take().first?.frame == RDPRect(x: 0, y: 0, width: 0, height: 0))
    }

    @Test func aNewWindowWithAnIdUsedBeforeStartsAfresh() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(notepad, fields: all)
        windows.apply(RDPRemoteWindow(id: 0x100, frame: RDPRect(x: 5, y: 5, width: 50, height: 50)), fields: [
            .new, .offset, .size
        ])
        let taken = try #require(windows.take().first)
        #expect(taken.title == "")
        #expect(taken.style == 0)
        #expect(taken.frame == RDPRect(x: 5, y: 5, width: 50, height: 50))
    }

    @Test func anIconArrivesTopRowFirstAndOnlyALargerOneReplacesIt() throws {
        let windows = try #require(RemoteAppWindows())
        windows.apply(notepad, fields: all)
        // Two rows of two pixels, bottom row first: blue below, red above.
        let blue: [UInt8] = [0xFF, 0, 0, 0xFF]
        let red: [UInt8] = [0, 0, 0xFF, 0xFF]
        windows.applyIcon(to: 0x100, width: 2, height: 2, bottomUp: blue + blue + red + red)

        let icon = try #require(windows.take().first?.icon)
        #expect(icon.width == 2 && icon.height == 2)
        #expect(Array(icon.pixels) == red + red + blue + blue)

        windows.applyIcon(to: 0x100, width: 1, height: 1, bottomUp: blue)
        #expect(windows.take().isEmpty)
    }
}

@Suite
struct RemoteAppEventTests {
    @Test func theRemoteComputersCodesSayWhyAProgramDidNotStart() {
        #expect(RDPProgramFailure(code: 0) == nil)
        #expect(RDPProgramFailure(code: 3) == .notPublished)
        #expect(RDPProgramFailure(code: 5) == .notFound)
        #expect(RDPProgramFailure(code: 7) == .sessionLocked)
        #expect(RDPProgramFailure(code: 6) == .failed(code: 6))
    }

    @Test func onlyTheLatestMoveOfAWindowWaits() {
        let first = RDPInputEvent.remoteApp(.move(windowID: 1, frame: RDPRect(x: 0, y: 0, width: 10, height: 10)))
        let later = RDPInputEvent.remoteApp(.move(windowID: 1, frame: RDPRect(x: 5, y: 5, width: 10, height: 10)))
        let other = RDPInputEvent.remoteApp(.move(windowID: 2, frame: RDPRect(x: 5, y: 5, width: 10, height: 10)))
        #expect(first.isSuperseded(by: later))
        #expect(!first.isSuperseded(by: other))
        #expect(!RDPInputEvent.remoteApp(.activate(windowID: 1, isActive: true))
            .isSuperseded(by: .remoteApp(.activate(windowID: 1, isActive: false))))
    }

    @Test func theLastWindowIsToldGoneOnceAfterTheGrace() {
        var watch = LastWindowWatch()
        let start = ContinuousClock.now
        let window = RDPRemoteWindow(id: 1, frame: RDPRect(x: 0, y: 0, width: 1, height: 1))
        // Nothing before the first window.
        let due1 = watch.isDue(at: start + .seconds(10), grace: .seconds(3))
        #expect(!due1)

        watch.note([window], at: start)
        watch.note([window.with { $0.isDeleted = true }], at: start + .seconds(1))
        let due2 = watch.isDue(at: start + .seconds(2), grace: .seconds(3))
        #expect(!due2)
        let due3 = watch.isDue(at: start + .seconds(4), grace: .seconds(3))
        #expect(due3)
        let due4 = watch.isDue(at: start + .seconds(9), grace: .seconds(3))
        #expect(!due4)

        // A window that comes back in time stops the clock.
        watch.note([window], at: start + .seconds(10))
        watch.note([window.with { $0.isDeleted = true }], at: start + .seconds(11))
        watch.note([window.with { $0.id = 2 }], at: start + .seconds(12))
        let due5 = watch.isDue(at: start + .seconds(20), grace: .seconds(3))
        #expect(!due5)
    }
}

extension RDPRemoteWindow {
    func with(_ change: (inout RDPRemoteWindow) -> Void) -> RDPRemoteWindow {
        var copy = self
        change(&copy)
        return copy
    }
}
