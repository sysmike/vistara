import AppKit
import Testing

@testable import RDPKit
@testable import RDPKitUI

@Suite
struct DesktopSizeTests {
    private func filling(_ width: CGFloat, _ height: CGFloat, scale: CGFloat = 1, hiDPI: Bool = true) -> DesktopSize? {
        DesktopSize.filling(viewSize: CGSize(width: width, height: height), backingScale: scale, usesHiDPI: hiDPI)
    }

    @Test func aStandardDisplayGetsOnePixelPerPoint() {
        #expect(filling(1280, 800) == DesktopSize(width: 1280, height: 800, scalePercent: 100))
    }

    @Test func aRetinaDisplayGetsEveryPixelAndTheMatchingScale() {
        #expect(filling(1280, 800, scale: 2) == DesktopSize(width: 2560, height: 1600, scalePercent: 200))
    }

    @Test func withoutHiDPIARetinaDisplayGetsOnePixelPerPoint() {
        #expect(filling(1280, 800, scale: 2, hiDPI: false) == DesktopSize(width: 1280, height: 800, scalePercent: 100))
    }

    @Test func theWidthIsEvenAndFractionsAreRounded() {
        #expect(filling(1001, 700.4) == DesktopSize(width: 1000, height: 700, scalePercent: 100))
        #expect(filling(640.5, 480.5, scale: 2) == DesktopSize(width: 1280, height: 961, scalePercent: 200))
    }

    @Test func sidesStayWithinWhatTheProtocolAllows() {
        #expect(filling(50, 60) == DesktopSize(width: 200, height: 200, scalePercent: 100))
        #expect(filling(6000, 5000, scale: 2) == DesktopSize(width: 8192, height: 8192, scalePercent: 200))
    }

    @Test func aViewWithoutSizeHasNoDesktopSize() {
        #expect(filling(0, 0) == nil)
        #expect(filling(.infinity, 100) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct SessionViewResizeTests {
    private final class Recorder {
        var events: [RDPInputEvent] = []
    }

    private struct Fixture {
        let view: RDPSessionView
        let window: NSWindow
        let recorder: Recorder
    }

    /// A view in a window of the given content size, showing a desktop of
    /// another size, set up to follow the window.
    private func makeView(
        content: NSSize, desktop: (width: Int, height: Int)?, resizes: Bool = true
    ) -> Fixture {
        let framebuffer = RDPFramebuffer()
        if let desktop {
            let pixels = [UInt8](repeating: 0, count: desktop.width * desktop.height * 4)
            pixels.withUnsafeBufferPointer {
                framebuffer.write(
                    from: $0, stride: desktop.width * 4, width: desktop.width, height: desktop.height,
                    dirty: .init(x: 0, y: 0, width: desktop.width, height: desktop.height)
                )
            }
        }
        let view = RDPSessionView(framebuffer: framebuffer, connectionName: "Build Server")
        view.resizeDelay = .milliseconds(20)
        let recorder = Recorder()
        view.inputHandler = { recorder.events.append(contentsOf: $0) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.resizesDesktop = resizes
        return Fixture(view: view, window: window, recorder: recorder)
    }

    private func sizeRequests(_ recorder: Recorder) -> [RDPInputEvent] {
        recorder.events.filter {
            if case .desktopSize = $0 { return true }
            return false
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test func theDesktopFollowsTheViewOnceItsSizeHasRested() async throws {
        let fixture = makeView(content: NSSize(width: 800, height: 600), desktop: (1024, 768))
        let (view, window, recorder) = (fixture.view, fixture.window, fixture.recorder)
        let first = try #require(view.fillingDesktopSize)
        #expect(Int(first.width) == Int(800 * window.backingScaleFactor))
        await settle()
        #expect(sizeRequests(recorder) == [
            .desktopSize(width: first.width, height: first.height, scalePercent: first.scalePercent)
        ])

        // Many sizes in quick succession, as in a live resize: one request.
        for width in stride(from: 810, through: 900, by: 10) {
            window.setContentSize(NSSize(width: width, height: 620))
        }
        await settle()
        let second = try #require(view.fillingDesktopSize)
        #expect(sizeRequests(recorder).count == 2)
        #expect(sizeRequests(recorder).last
            == .desktopSize(width: second.width, height: second.height, scalePercent: second.scalePercent))

        // The same size again asks for nothing.
        window.setContentSize(NSSize(width: 900, height: 620))
        await settle()
        #expect(sizeRequests(recorder).count == 2)
        window.contentView = nil
    }

    @Test func nothingIsAskedBeforeThereIsADesktop() async {
        let fixture = makeView(content: NSSize(width: 800, height: 600), desktop: nil)
        #expect(fixture.view.fillingDesktopSize != nil)
        await settle()
        // Not connected yet: nothing to resize.
        #expect(sizeRequests(fixture.recorder).isEmpty)
        fixture.window.contentView = nil
    }

    @Test func aViewThatDoesNotFollowNeverAsks() async {
        let fixture = makeView(content: NSSize(width: 800, height: 600), desktop: (1024, 768), resizes: false)
        fixture.window.setContentSize(NSSize(width: 900, height: 620))
        await settle()
        #expect(sizeRequests(fixture.recorder).isEmpty)
        fixture.window.contentView = nil
    }

    @Test func onlyTheLatestOfSeveralSizesIsWorthSending() {
        let small = RDPInputEvent.desktopSize(width: 800, height: 600, scalePercent: 100)
        let large = RDPInputEvent.desktopSize(width: 1280, height: 800, scalePercent: 100)
        #expect(small.isSuperseded(by: large))
        #expect(RDPInputEvent.pointerMove(x: 1, y: 1).isSuperseded(by: .pointerMove(x: 2, y: 2)))
        #expect(!small.isSuperseded(by: .pointerMove(x: 1, y: 1)))
        #expect(!RDPInputEvent.key(.leftShift, isDown: true).isSuperseded(by: .key(.leftShift, isDown: true)))
    }
}
