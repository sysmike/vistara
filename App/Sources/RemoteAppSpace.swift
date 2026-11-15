import AppKit
import RDPKit

/// Where a RemoteApp session's desktop lies on the Mac (docs/DESIGN.md,
/// RemoteApp): every display, arranged as in System Settings, at one pixel
/// density, so a window's frame converts the same way whichever display it
/// is on. The remote computer counts from the main display's top left, y
/// down; the Mac from its bottom left, y up.
struct RemoteAppSpace: Equatable {
    /// The displays' frames, the main one first, as `NSScreen.frame`.
    var displays: [CGRect]
    /// The main display's visible frame: without the menu bar and the Dock.
    var visibleMain: CGRect
    /// Remote pixels per point.
    var scale: CGFloat

    /// RDP's largest desktop side.
    static let maximumSide: CGFloat = 8192

    /// The Mac's displays now. With `usesHiDPI`, at the main display's
    /// density, unless the desktop would then be too large.
    static func current(usesHiDPI: Bool) -> RemoteAppSpace {
        let screens = NSScreen.screens
        let main = screens.first
        return RemoteAppSpace(
            displays: screens.map(\.frame), visibleMain: main?.visibleFrame ?? .zero,
            usesHiDPI: usesHiDPI, backingScale: main?.backingScaleFactor ?? 1
        )
    }

    init(displays: [CGRect], visibleMain: CGRect, usesHiDPI: Bool, backingScale: CGFloat) {
        self.displays = displays.isEmpty ? [CGRect(x: 0, y: 0, width: 1280, height: 800)] : displays
        self.visibleMain = visibleMain
        let union = self.displays.dropFirst().reduce(self.displays[0]) { $0.union($1) }
        let wanted = usesHiDPI ? max(backingScale, 1) : 1
        let largest = max(union.width, union.height, 1)
        scale = min(wanted, max(1, (Self.maximumSide / largest).rounded(.down)))
    }

    private var main: CGRect { displays[0] }

    /// Each display as a remote monitor, the main one primary.
    var monitors: [RDPMonitor] {
        displays.enumerated().map { index, display in
            let rect = remoteRect(for: display)
            return RDPMonitor(
                x: Int32(rect.x), y: Int32(rect.y), width: UInt32(rect.width), height: UInt32(rect.height),
                isPrimary: index == 0, scalePercent: UInt32((scale * 100).rounded())
            )
        }
    }

    /// The framebuffer covers the monitors' bounding box.
    var boundingBox: RDPFramebuffer.Rect {
        RDPMonitor.boundingBox(of: monitors)
    }

    /// Where a maximized window goes: the main display without the menu bar
    /// and the Dock.
    var workArea: RDPRect {
        remoteRect(for: visibleMain)
    }

    /// A rectangle of the Mac's screens on the remote desktop.
    func remoteRect(for screen: CGRect) -> RDPRect {
        RDPRect(
            x: Int(((screen.minX - main.minX) * scale).rounded()),
            y: Int(((main.maxY - screen.maxY) * scale).rounded()),
            width: Int((screen.width * scale).rounded()),
            height: Int((screen.height * scale).rounded())
        )
    }

    /// A rectangle of the remote desktop on the Mac's screens.
    func screenRect(for remote: RDPRect) -> CGRect {
        CGRect(
            x: main.minX + CGFloat(remote.x) / scale,
            y: main.maxY - CGFloat(remote.y + remote.height) / scale,
            width: CGFloat(remote.width) / scale,
            height: CGFloat(remote.height) / scale
        )
    }

    /// A point of the Mac's screens as the pointer goes to the remote
    /// computer: in framebuffer pixels.
    func framebufferPoint(for screen: CGPoint) -> (x: UInt16, y: UInt16) {
        let box = boundingBox
        let x = (screen.x - main.minX) * scale - CGFloat(box.x)
        let y = (main.maxY - screen.y) * scale - CGFloat(box.y)
        return (UInt16(clamping: Int(x.rounded(.down))), UInt16(clamping: Int(y.rounded(.down))))
    }

    /// The part of the framebuffer that shows a remote rectangle.
    func framebufferRegion(for remote: RDPRect) -> CGRect {
        let box = boundingBox
        return CGRect(x: remote.x - box.x, y: remote.y - box.y, width: remote.width, height: remote.height)
    }
}
