import CoreGraphics
import Testing

@testable import RDPKitUI

/// The Mac's displays as remote monitors (#111). Frames are in points with y
/// up, as `NSScreen` gives them; monitors are in remote pixels with y down.
@Suite
struct DisplayLayoutTests {
    private typealias Display = DisplayLayout.Display

    private func display(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                         scale: CGFloat = 1, main: Bool = false) -> Display {
        Display(frame: CGRect(x: x, y: y, width: width, height: height), backingScale: scale, isMain: main)
    }

    private func layout(_ displays: [Display], usesHiDPI: Bool = true) -> [DisplayLayout.Monitor] {
        let monitors = DisplayLayout.monitors(for: displays, usesHiDPI: usesHiDPI)
        expectSound(monitors, of: displays)
        return monitors
    }

    /// What every layout must be: one primary at the origin, first; no
    /// overlaps; every monitor reachable from the primary over shared edges;
    /// each display used once.
    private func expectSound(
        _ monitors: [DisplayLayout.Monitor], of displays: [Display], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let primary = monitors.first else {
            #expect(displays.isEmpty, sourceLocation: sourceLocation)
            return
        }
        #expect(primary.isPrimary && primary.x == 0 && primary.y == 0, sourceLocation: sourceLocation)
        #expect(monitors.dropFirst().allSatisfy { !$0.isPrimary }, sourceLocation: sourceLocation)
        #expect(Set(monitors.map(\.displayIndex)).count == monitors.count, sourceLocation: sourceLocation)
        for (index, one) in monitors.enumerated() {
            for other in monitors[(index + 1)...] {
                #expect(!DisplayLayout.overlaps(one, other), "\(one) overlaps \(other)", sourceLocation: sourceLocation)
            }
        }
        var reached: Set<Int> = [0]
        var queue = [0]
        while let next = queue.popLast() {
            for index in monitors.indices where !reached.contains(index)
                && DisplayLayout.touch(monitors[next], monitors[index]) {
                reached.insert(index)
                queue.append(index)
            }
        }
        #expect(reached.count == monitors.count, "separated: \(monitors)", sourceLocation: sourceLocation)
    }

    private func position(_ monitor: DisplayLayout.Monitor) -> [Int] {
        [monitor.x, monitor.y, monitor.width, monitor.height]
    }

    @Test func aSingleDisplayIsThePrimaryAtTheOrigin() {
        let monitors = layout([display(0, 0, 1512, 982, scale: 2, main: true)])
        #expect(monitors.map(position) == [[0, 0, 3024, 1964]])
        #expect(monitors.first?.size.scalePercent == 200)
        #expect(layout([]).isEmpty)
    }

    @Test func sideBySide() {
        let monitors = layout([display(0, 0, 1920, 1080, main: true), display(1920, 0, 1920, 1080)])
        #expect(monitors.map(position) == [[0, 0, 1920, 1080], [1920, 0, 1920, 1080]])
    }

    @Test func stacked() {
        let monitors = layout([display(0, 0, 1920, 1080, main: true), display(0, 1080, 1920, 1080)])
        #expect(monitors.map(position) == [[0, 0, 1920, 1080], [0, -1080, 1920, 1080]])
    }

    /// The second display's top is 244 points above the main one's.
    @Test func offsetAlignmentIsKept() {
        let monitors = layout([display(0, 0, 1920, 1080, main: true), display(1920, 300, 1280, 1024)])
        #expect(monitors.map(position) == [[0, 0, 1920, 1080], [1920, -244, 1280, 1024]])
    }

    @Test func theMainDisplayNeedNotBeLeftmost() {
        let monitors = layout([display(-2560, 0, 2560, 1440), display(0, 0, 1920, 1080, main: true)])
        #expect(monitors.map(\.displayIndex) == [1, 0])
        #expect(monitors.map(position) == [[0, 0, 1920, 1080], [-2560, -360, 2560, 1440]])
    }

    /// A Retina laptop with a standard display to its right: each at its own
    /// density, the offset in the laptop's pixels.
    @Test func aRetinaDisplayBesideAStandardOne() {
        let monitors = layout([display(0, 0, 1512, 982, scale: 2, main: true), display(1512, 0, 1920, 1080)])
        #expect(monitors.map(position) == [[0, 0, 3024, 1964], [3024, -196, 1920, 1080]])
        #expect(monitors.map(\.size.scalePercent) == [200, 100])
    }

    @Test func aRetinaDisplayAboveAStandardOne() {
        let monitors = layout([display(0, 0, 2560, 1440, main: true), display(500, 1440, 1512, 982, scale: 2)])
        #expect(monitors.map(position) == [[0, 0, 2560, 1440], [500, -1964, 3024, 1964]])
    }

    /// Mixed densities can make an exact copy overlap: the display above both
    /// is moved up until it no longer does, and still touches one of them.
    @Test func anOverlapFromMixedDensitiesIsMovedOut() {
        let displays = [
            display(0, 0, 1512, 982, scale: 2, main: true),
            display(1512, 0, 1920, 1080),
            display(800, 982, 1920, 1080)
        ]
        let monitors = layout(displays)
        #expect(monitors.count == 3)
    }

    @Test func withoutHiDPIEachPointIsAPixel() {
        let monitors = layout([display(0, 0, 1512, 982, scale: 2, main: true)], usesHiDPI: false)
        #expect(monitors.map(position) == [[0, 0, 1512, 982]])
        #expect(monitors.first?.size.scalePercent == 100)
    }

    @Test func atMostSixteenMonitors() {
        let row = (0..<17).map { display(CGFloat($0) * 1000, 0, 1000, 800, main: $0 == 0) }
        let monitors = layout(row)
        #expect(monitors.count == DisplayLayout.maximumMonitors)
        // The furthest one is left out.
        #expect(!monitors.map(\.displayIndex).contains(16))
    }

    /// A display touching none (macOS normally prevents it) still ends up
    /// beside one, so the remote desktop has no gap.
    @Test func aDisplayTouchingNoneIsPlacedBesideTheNearest() {
        let monitors = layout([display(0, 0, 1920, 1080, main: true), display(2500, 100, 1280, 1024)])
        #expect(monitors.count == 2)
    }

    @Test func noDisplayIsMarkedMainTheFirstIsPrimary() {
        let monitors = layout([display(0, 0, 1920, 1080), display(1920, 0, 1920, 1080)])
        #expect(monitors.first?.displayIndex == 0)
    }
}
