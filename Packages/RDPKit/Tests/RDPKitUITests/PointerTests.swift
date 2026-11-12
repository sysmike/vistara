import AppKit
import Testing

@testable import RDPKit
@testable import RDPKitUI

private let desktop = CGSize(width: 1024, height: 768)

private func point(_ x: UInt16, _ y: UInt16) -> DesktopPoint {
    DesktopPoint(x: x, y: y)
}

@Suite
struct PointerMapperTests {
    private func map(_ x: CGFloat, _ y: CGFloat, view: CGSize, clamped: Bool = false) -> DesktopPoint? {
        PointerMapper.desktopPoint(at: CGPoint(x: x, y: y), viewSize: view, desktopSize: desktop, clamped: clamped)
    }

    @Test func atFullSizeEveryPointIsItsOwnPixel() {
        // The view counts from the bottom left, the desktop from the top left.
        #expect(map(0.5, 767.5, view: desktop) == point(0, 0))
        #expect(map(10.2, 767.9 - 5, view: desktop) == point(10, 5))
        #expect(map(1023.9, 0.1, view: desktop) == point(1023, 767))
    }

    @Test func aRetinaDisplayChangesNothingBecauseViewsCountInPoints() {
        // A 2x session: 2048x1536 remote pixels shown in 1024x768 points.
        let retina = CGSize(width: 2048, height: 1536)
        let result = PointerMapper.desktopPoint(
            at: CGPoint(x: 100.25, y: 768 - 50.25), viewSize: desktop, desktopSize: retina, clamped: false
        )
        #expect(result == point(200, 100))
    }

    @Test func aSmallerViewScalesThePosition() {
        let half = CGSize(width: 512, height: 384)
        #expect(map(256, 192, view: half) == point(512, 384))
        #expect(map(511.9, 0.1, view: half) == point(1023, 767))
    }

    @Test func barsBesideTheDesktopAreNotPartOfIt() {
        // Twice as wide as needed: the desktop sits between x 512 and 1536.
        let wide = CGSize(width: 2048, height: 768)
        #expect(map(100, 400, view: wide) == nil)
        #expect(map(512.5, 767.5, view: wide) == point(0, 0))
        #expect(map(1535.5, 0.5, view: wide) == point(1023, 767))
        #expect(map(1600, 400, view: wide) == nil)
    }

    @Test func aDragBesideTheDesktopStaysAtItsEdge() {
        let wide = CGSize(width: 2048, height: 768)
        #expect(map(100, 400, view: wide, clamped: true) == point(0, 368))
        #expect(map(5000, -50, view: wide, clamped: true) == point(1023, 767))
        #expect(map(-10, 9000, view: wide, clamped: true) == point(0, 0))
    }

    @Test func nothingMapsBeforeThereIsADesktop() {
        let result = PointerMapper.desktopPoint(
            at: CGPoint(x: 10, y: 10), viewSize: desktop, desktopSize: .zero, clamped: true
        )
        #expect(result == nil)
    }
}

@Suite
struct ScrollAccumulatorTests {
    private typealias Turn = ScrollAccumulator.Turn

    @Test func oneNotchOfAMouseWheelIsOneNotch() {
        var scroll = ScrollAccumulator()
        #expect(scroll.add(deltaX: 0, deltaY: 1, isPrecise: false) == [Turn(axis: .vertical, rotation: 120)])
        #expect(scroll.add(deltaX: 0, deltaY: -1, isPrecise: false) == [Turn(axis: .vertical, rotation: -120)])
    }

    @Test func smallTrackpadDistancesAddUpToQuarterNotches() {
        var scroll = ScrollAccumulator()
        // 3 units per point: 4 points are 12 units, not yet a step of 30.
        #expect(scroll.add(deltaX: 0, deltaY: 4, isPrecise: true).isEmpty)
        #expect(scroll.add(deltaX: 0, deltaY: 4, isPrecise: true).isEmpty)
        #expect(scroll.add(deltaX: 0, deltaY: 4, isPrecise: true) == [Turn(axis: .vertical, rotation: 30)])
        // 6 units are left over and count towards the next step.
        #expect(scroll.add(deltaX: 0, deltaY: 8, isPrecise: true) == [Turn(axis: .vertical, rotation: 30)])
    }

    @Test func nothingIsLostOverALongGesture() {
        var scroll = ScrollAccumulator()
        var total = 0
        for _ in 0..<400 {
            total += scroll.add(deltaX: 0, deltaY: -1.5, isPrecise: true).reduce(0) { $0 + Int($1.rotation) }
        }
        #expect(total == -1800)
    }

    @Test func contentMovingRightMeansTheWheelTurnedLeft() {
        var scroll = ScrollAccumulator()
        #expect(scroll.add(deltaX: 1, deltaY: 0, isPrecise: false) == [Turn(axis: .horizontal, rotation: -120)])
    }

    @Test func aLargeDeltaIsSplitIntoTurnsTheProtocolCanCarry() {
        var scroll = ScrollAccumulator()
        let turns = scroll.add(deltaX: 0, deltaY: 5, isPrecise: false)
        #expect(turns.map(\.rotation) == [240, 240, 120])
        #expect(turns.allSatisfy { abs(Int($0.rotation)) <= 255 })
    }

    @Test func aNewGestureStartsFromNothing() {
        var scroll = ScrollAccumulator()
        _ = scroll.add(deltaX: 0, deltaY: 9, isPrecise: true)
        scroll.reset()
        #expect(scroll.add(deltaX: 0, deltaY: 1, isPrecise: true).isEmpty)
    }
}

@Suite
struct PointerTranslatorTests {
    private let full = PointerTranslator.Geometry(viewSize: desktop, desktopSize: desktop)
    private let wide = PointerTranslator.Geometry(viewSize: CGSize(width: 2048, height: 768), desktopSize: desktop)

    @Test func movesAreSentOncePerPixel() {
        var pointer = PointerTranslator()
        #expect(pointer.moved(to: CGPoint(x: 100.2, y: 700.2), in: full) == [.pointerMove(x: 100, y: 67)])
        #expect(pointer.moved(to: CGPoint(x: 100.7, y: 700.6), in: full).isEmpty)
        #expect(pointer.moved(to: CGPoint(x: 101.2, y: 700.2), in: full) == [.pointerMove(x: 101, y: 67)])
    }

    @Test func everyButtonGoesDownAndUpWhereThePointerIs() {
        var pointer = PointerTranslator()
        let place = CGPoint(x: 10.5, y: 757.5)
        for button in RDPPointerButton.allCases {
            #expect(pointer.button(button, isDown: true, at: place, in: full)
                == [.pointerButton(button, isDown: true, x: 10, y: 10)])
            #expect(pointer.button(button, isDown: false, at: place, in: full)
                == [.pointerButton(button, isDown: false, x: 10, y: 10)])
        }
    }

    @Test func aDragContinuesAlongTheEdgeAndEndsThere() {
        var pointer = PointerTranslator()
        _ = pointer.button(.left, isDown: true, at: CGPoint(x: 600, y: 400), in: wide)
        #expect(pointer.moved(to: CGPoint(x: 100, y: 400), in: wide) == [.pointerMove(x: 0, y: 368)])
        #expect(pointer.button(.left, isDown: false, at: CGPoint(x: 100, y: 400), in: wide)
            == [.pointerButton(.left, isDown: false, x: 0, y: 368)])
        // With no button held, the bars are not part of the desktop again.
        #expect(pointer.moved(to: CGPoint(x: 90, y: 400), in: wide).isEmpty)
    }

    @Test func aClickBesideTheDesktopIsNotSent() {
        var pointer = PointerTranslator()
        #expect(pointer.button(.left, isDown: true, at: CGPoint(x: 100, y: 400), in: wide).isEmpty)
        #expect(pointer.button(.left, isDown: false, at: CGPoint(x: 600, y: 400), in: wide).isEmpty)
    }

    @Test func heldButtonsAreReleasedWhenTheSessionLosesAttention() {
        var pointer = PointerTranslator()
        _ = pointer.button(.left, isDown: true, at: CGPoint(x: 10.5, y: 757.5), in: full)
        _ = pointer.button(.right, isDown: true, at: CGPoint(x: 10.5, y: 757.5), in: full)
        _ = pointer.moved(to: CGPoint(x: 20.5, y: 747.5), in: full)
        #expect(pointer.releaseButtons() == [
            .pointerButton(.left, isDown: false, x: 20, y: 20), .pointerButton(.right, isDown: false, x: 20, y: 20)
        ])
        #expect(pointer.releaseButtons().isEmpty)
        #expect(pointer.button(.left, isDown: false, at: CGPoint(x: 20.5, y: 747.5), in: full).isEmpty)
    }

    @Test func scrollingHappensWhereThePointerIs() {
        var pointer = PointerTranslator()
        let delta = PointerTranslator.ScrollDelta(x: 0, y: 1, isPrecise: false)
        #expect(pointer.scrolled(delta, at: CGPoint(x: 10.5, y: 757.5), in: full)
            == [.wheel(.vertical, rotation: 120, x: 10, y: 10)])
        #expect(pointer.scrolled(delta, at: CGPoint(x: 100, y: 400), in: wide).isEmpty)
    }
}

@Suite
@MainActor
struct CursorTests {
    private func shape(width: Int = 2, height: Int = 2, bytes: [UInt8]) -> RDPCursorImage {
        RDPCursorImage(width: width, height: height, hotspotX: 1, hotspotY: 0, pixels: Data(bytes))
    }

    // Blue, green, red, alpha for each pixel: red, green, blue, and nothing.
    private let fourPixels: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0]

    @Test func theImageKeepsSizeAndStraightAlpha() throws {
        let image = try #require(CursorFactory.image(from: shape(bytes: fourPixels)))
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.alphaInfo == .first)
    }

    @Test func pixelsThatDoNotMatchTheSizeGiveNoImage() {
        #expect(CursorFactory.image(from: shape(bytes: [0, 0, 0])) == nil)
        #expect(CursorFactory.image(from: shape(width: 0, height: 2, bytes: [])) == nil)
        #expect(CursorFactory.cursor(for: .image(shape(bytes: [1, 2, 3])), pointsPerPixel: 1) == nil)
    }

    @Test func theCursorIsScaledWithTheDesktop() throws {
        let cursor = try #require(CursorFactory.cursor(for: .image(shape(bytes: fourPixels)), pointsPerPixel: 0.5))
        #expect(cursor.image.size == NSSize(width: 1, height: 1))
        #expect(cursor.hotSpot == NSPoint(x: 0.5, y: 0))

        let full = try #require(CursorFactory.cursor(for: .image(shape(bytes: fourPixels)), pointsPerPixel: 1))
        #expect(full.image.size == NSSize(width: 2, height: 2))
        #expect(full.hotSpot == NSPoint(x: 1, y: 0))
    }

    @Test func theSystemArrowIsNoCursorOfOurs() {
        #expect(CursorFactory.cursor(for: .systemDefault, pointsPerPixel: 1) == nil)
        #expect(CursorFactory.cursor(for: .hidden, pointsPerPixel: 1) === CursorFactory.hidden)
    }

    @Test func theViewShowsTheRemoteCursorOverTheDesktop() {
        let framebuffer = RDPFramebuffer()
        let view = RDPSessionView(framebuffer: framebuffer, connectionName: "Build Server")
        #expect(view.desktopCursor == nil)

        framebuffer.setCursor(.image(shape(bytes: fourPixels)))
        view.consumeUpdate()
        #expect(view.desktopCursor != nil)

        framebuffer.setCursor(.systemDefault)
        view.consumeUpdate()
        #expect(view.desktopCursor == nil)
    }

    @Test func extraMouseButtonsMapToMiddleBackAndForward() {
        #expect(RDPSessionView.otherButton(2) == .middle)
        #expect(RDPSessionView.otherButton(3) == .back)
        #expect(RDPSessionView.otherButton(4) == .forward)
        #expect(RDPSessionView.otherButton(7) == nil)
    }
}
