import CoreGraphics

/// The desktop size to ask the remote computer for, so that it fills a view
/// pixel for pixel.
public struct DesktopSize: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    /// 100 for standard displays, 200 for Retina.
    public var scalePercent: UInt16

    public init(width: UInt16, height: UInt16, scalePercent: UInt16) {
        self.width = width
        self.height = height
        self.scalePercent = scalePercent
    }

    /// The smallest and largest sides the display control protocol allows.
    static let sideRange: ClosedRange<CGFloat> = 200...8192

    /// The size for a view of `viewSize` points on a display that draws
    /// `backingScale` pixels per point.
    ///
    /// With `usesHiDPI`, the desktop gets every pixel of a Retina display and
    /// is told to draw at the matching scale, so text is sharp and as large
    /// as on the Mac. Without it, the desktop gets one pixel per point and is
    /// magnified.
    ///
    /// Returns nil while the view has no size. The width is made even, as
    /// the protocol requires.
    public static func filling(viewSize: CGSize, backingScale: CGFloat, usesHiDPI: Bool) -> DesktopSize? {
        guard viewSize.width >= 1, viewSize.height >= 1, viewSize.width.isFinite, viewSize.height.isFinite else {
            return nil
        }
        let scale = usesHiDPI ? min(max(backingScale, 1), 5) : 1
        let width = Self.clamped(viewSize.width * scale)
        let height = Self.clamped(viewSize.height * scale)
        return DesktopSize(
            width: UInt16(width) & ~1,
            height: UInt16(height),
            scalePercent: UInt16((scale * 100).rounded())
        )
    }

    private static func clamped(_ side: CGFloat) -> CGFloat {
        min(max(side.rounded(), sideRange.lowerBound), sideRange.upperBound)
    }
}
