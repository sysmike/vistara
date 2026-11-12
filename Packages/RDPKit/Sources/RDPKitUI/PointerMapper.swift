import CoreGraphics

/// A position on the remote desktop, in its pixels, origin at the top left.
struct DesktopPoint: Equatable {
    var x: UInt16
    var y: UInt16
}

/// Finds the remote pixel under a point of the view. The view shows the
/// desktop scaled to fit and centred, and counts its own points from the
/// bottom left. Because the result follows from proportions alone, it is the
/// same on standard and Retina displays.
enum PointerMapper {
    /// Returns nil for a point beside the desktop, unless `clamped`, which
    /// gives the nearest pixel instead. Dragging uses that, so a drag can
    /// leave the desktop and still end.
    static func desktopPoint(
        at point: CGPoint, viewSize: CGSize, desktopSize: CGSize, clamped: Bool
    ) -> DesktopPoint? {
        let frame = FitLayout.frame(content: desktopSize, container: viewSize)
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard clamped || frame.contains(point) else { return nil }

        let column = ((point.x - frame.minX) / frame.width * desktopSize.width).rounded(.down)
        let row = ((frame.maxY - point.y) / frame.height * desktopSize.height).rounded(.down)
        return DesktopPoint(
            x: UInt16(min(max(column, 0), min(desktopSize.width - 1, CGFloat(UInt16.max)))),
            y: UInt16(min(max(row, 0), min(desktopSize.height - 1, CGFloat(UInt16.max))))
        )
    }
}
