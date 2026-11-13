internal import CFreeRDP

/// One of the remote computer's monitors, in remote pixels relative to the
/// primary monitor's top left (docs/DESIGN.md, Multiple displays). The
/// primary is at the origin; others may lie at negative coordinates.
public struct RDPMonitor: Sendable, Hashable {
    public var x: Int32
    public var y: Int32
    public var width: UInt32
    public var height: UInt32
    public var isPrimary: Bool
    /// 100 for standard displays, 200 for Retina.
    public var scalePercent: UInt32

    public init(x: Int32, y: Int32, width: UInt32, height: UInt32, isPrimary: Bool, scalePercent: UInt32 = 100) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
        self.scalePercent = scalePercent
    }

    /// RDP's limit on monitors in one session.
    public static let maximumCount = Int(VISTARA_MAX_MONITORS)

    /// The desktop the monitors make: their bounding box, in the same
    /// coordinates. The framebuffer is this size, with its top left at the
    /// box's.
    public static func boundingBox(of monitors: [RDPMonitor]) -> RDPFramebuffer.Rect {
        guard let first = monitors.first else { return RDPFramebuffer.Rect(x: 0, y: 0, width: 0, height: 0) }
        var left = Int(first.x), top = Int(first.y)
        var right = left + Int(first.width), bottom = top + Int(first.height)
        for monitor in monitors.dropFirst() {
            left = min(left, Int(monitor.x))
            top = min(top, Int(monitor.y))
            right = max(right, Int(monitor.x) + Int(monitor.width))
            bottom = max(bottom, Int(monitor.y) + Int(monitor.height))
        }
        return RDPFramebuffer.Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Where this monitor is in a framebuffer of the desktop `box`, the
    /// monitors' bounding box.
    public func framebufferRect(in box: RDPFramebuffer.Rect) -> RDPFramebuffer.Rect {
        RDPFramebuffer.Rect(x: Int(x) - box.x, y: Int(y) - box.y, width: Int(width), height: Int(height))
    }

    var cMonitor: vistara_monitor {
        vistara_monitor(
            x: x, y: y, width: width, height: height, is_primary: isPrimary, scale_percent: scalePercent
        )
    }
}
