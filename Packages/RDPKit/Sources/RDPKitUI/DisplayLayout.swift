import CoreGraphics

/// The Mac's displays as the remote computer's monitors: the same order and
/// alignment, the main display as the primary monitor, each display at its own
/// pixel density (docs/DESIGN.md, Multiple displays).
public enum DisplayLayout {
    /// One of the Mac's displays.
    public struct Display: Equatable, Sendable {
        /// Where the display is, in points, in the Mac's global coordinates:
        /// origin at the main display's bottom left, y up, as `NSScreen.frame`.
        public var frame: CGRect
        /// Pixels per point.
        public var backingScale: CGFloat
        /// The display with the menu bar.
        public var isMain: Bool
        /// The size a full-screen window gets on it, where that is less than
        /// the frame, as below a camera housing.
        public var usableSize: CGSize?

        public init(frame: CGRect, backingScale: CGFloat, isMain: Bool, usableSize: CGSize? = nil) {
            self.frame = frame
            self.backingScale = backingScale
            self.isMain = isMain
            self.usableSize = usableSize
        }
    }

    /// A remote monitor, in the remote desktop's pixels: origin at the
    /// primary monitor's top left, y down, as RDP requires.
    public struct Monitor: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var size: DesktopSize
        public var isPrimary: Bool
        /// The display it shows, as an index into the displays given.
        public var displayIndex: Int

        public init(x: Int, y: Int, size: DesktopSize, isPrimary: Bool, displayIndex: Int) {
            self.x = x
            self.y = y
            self.size = size
            self.isPrimary = isPrimary
            self.displayIndex = displayIndex
        }

        public var width: Int { Int(size.width) }
        public var height: Int { Int(size.height) }
        var maxX: Int { x + width }
        var maxY: Int { y + height }
    }

    /// RDP's limit on monitors in one session.
    public static let maximumMonitors = 16

    /// The monitors for `displays`, primary first, then outward from it.
    /// Displays that touch on the Mac touch remotely. Where densities differ
    /// and the arrangement cannot be kept exactly in whole pixels, a display's
    /// offset along a shared edge is scaled and kept within the edge, and one
    /// that would overlap another is moved out until it touches instead.
    /// Beyond `maximumMonitors`, the displays furthest from the main one are
    /// left out.
    public static func monitors(for displays: [Display], usesHiDPI: Bool) -> [Monitor] {
        guard let primary = displays.firstIndex(where: \.isMain) ?? displays.indices.first,
            let primarySize = size(of: displays[primary], usesHiDPI: usesHiDPI)
        else { return [] }
        var placed = [Monitor(x: 0, y: 0, size: primarySize, isPrimary: true, displayIndex: primary)]
        var waiting = displays.indices.filter { $0 != primary }

        func add(_ index: Int, beside neighbour: Monitor, on side: Side) {
            waiting.removeAll { $0 == index }
            guard let size = Self.size(of: displays[index], usesHiDPI: usesHiDPI) else { return }
            let monitor = place(size, index: index, beside: neighbour, on: side, in: displays)
            placed.append(moveOut(monitor, from: placed, on: side))
        }

        // Outward from the primary: first the displays touching it, then
        // those touching them, and so on.
        var frontier = 0
        while !waiting.isEmpty, placed.count < maximumMonitors {
            if frontier < placed.count {
                let anchor = placed[frontier]
                frontier += 1
                let anchorFrame = displays[anchor.displayIndex].frame
                for index in waiting where placed.count < maximumMonitors {
                    if let side = Self.side(of: displays[index].frame, touching: anchorFrame) {
                        add(index, beside: anchor, on: side)
                    }
                }
            } else if let nearest = Self.nearest(of: waiting, to: placed, in: displays) {
                // Touching none placed: beside the nearest one.
                let frame = displays[nearest.index].frame
                let side = dominantSide(of: frame, from: displays[nearest.neighbour.displayIndex].frame)
                add(nearest.index, beside: nearest.neighbour, on: side)
            } else {
                break
            }
        }
        return placed
    }

    // MARK: Placing

    /// Where a display lies against another, as the remote computer sees it.
    enum Side {
        case right, left, above, below
    }

    private static func size(of display: Display, usesHiDPI: Bool) -> DesktopSize? {
        DesktopSize.filling(
            viewSize: display.usableSize ?? display.frame.size, backingScale: display.backingScale, usesHiDPI: usesHiDPI
        )
    }

    /// The side of `anchor` that `frame` shares an edge with, in points.
    static func side(of frame: CGRect, touching anchor: CGRect) -> Side? {
        let tolerance: CGFloat = 1
        let sharesVertical = min(frame.maxY, anchor.maxY) - max(frame.minY, anchor.minY) > 0
        let sharesHorizontal = min(frame.maxX, anchor.maxX) - max(frame.minX, anchor.minX) > 0
        if sharesVertical, abs(frame.minX - anchor.maxX) <= tolerance { return .right }
        if sharesVertical, abs(frame.maxX - anchor.minX) <= tolerance { return .left }
        // The Mac's y points up; above on the Mac is above remotely.
        if sharesHorizontal, abs(frame.minY - anchor.maxY) <= tolerance { return .above }
        if sharesHorizontal, abs(frame.maxY - anchor.minY) <= tolerance { return .below }
        return nil
    }

    /// For a display touching no other: the side its centre lies furthest towards.
    private static func dominantSide(of frame: CGRect, from anchor: CGRect) -> Side {
        let across = frame.midX - anchor.midX
        let upward = frame.midY - anchor.midY
        if abs(across) >= abs(upward) { return across >= 0 ? .right : .left }
        return upward >= 0 ? .above : .below
    }

    /// The waiting display nearest to a placed monitor, centre to centre.
    private static func nearest(
        of waiting: [Int], to placed: [Monitor], in displays: [Display]
    ) -> (index: Int, neighbour: Monitor)? {
        let pairs = waiting.flatMap { index in placed.map { (index: index, neighbour: $0) } }
        return pairs.min { one, other in
            distance(displays[one.index].frame, displays[one.neighbour.displayIndex].frame)
                < distance(displays[other.index].frame, displays[other.neighbour.displayIndex].frame)
        }
    }

    private static func distance(_ one: CGRect, _ other: CGRect) -> CGFloat {
        hypot(one.midX - other.midX, one.midY - other.midY)
    }

    /// Beside `neighbour` on `side`, with the offset along the shared edge
    /// taken from the Mac in the neighbour's pixels per point, and kept so
    /// that the two still share some of the edge.
    private static func place(
        _ size: DesktopSize, index: Int, beside neighbour: Monitor, on side: Side, in displays: [Display]
    ) -> Monitor {
        let display = displays[index]
        let neighbourDisplay = displays[neighbour.displayIndex]
        let width = Int(size.width)
        let height = Int(size.height)
        let across = CGFloat(neighbour.width) / max(neighbourDisplay.frame.width, 1)
        let down = CGFloat(neighbour.height) / max(neighbourDisplay.frame.height, 1)
        var x = neighbour.x
        var y = neighbour.y
        switch side {
        case .right, .left:
            x = side == .right ? neighbour.maxX : neighbour.x - width
            // Top edges, with y pointing down: the Mac's maxY is the top.
            let offset = Int(((neighbourDisplay.frame.maxY - display.frame.maxY) * down).rounded())
            y = min(max(neighbour.y + offset, neighbour.y - height + 1), neighbour.maxY - 1)
        case .above, .below:
            y = side == .above ? neighbour.y - height : neighbour.maxY
            let offset = Int(((display.frame.minX - neighbourDisplay.frame.minX) * across).rounded())
            x = min(max(neighbour.x + offset, neighbour.x - width + 1), neighbour.maxX - 1)
        }
        return Monitor(x: x, y: y, size: size, isPrimary: false, displayIndex: index)
    }

    /// Moves `monitor` away along `side` until it overlaps none placed; it
    /// then touches the one it was moved off.
    private static func moveOut(_ monitor: Monitor, from placed: [Monitor], on side: Side) -> Monitor {
        var monitor = monitor
        while let other = placed.first(where: { overlaps($0, monitor) }) {
            switch side {
            case .right: monitor.x = other.maxX
            case .left: monitor.x = other.x - monitor.width
            case .above: monitor.y = other.y - monitor.height
            case .below: monitor.y = other.maxY
            }
        }
        return monitor
    }

    static func overlaps(_ one: Monitor, _ other: Monitor) -> Bool {
        one.x < other.maxX && other.x < one.maxX && one.y < other.maxY && other.y < one.maxY
    }

    /// Whether two monitors share some of an edge.
    static func touch(_ one: Monitor, _ other: Monitor) -> Bool {
        let sharesVertical = min(one.maxY, other.maxY) > max(one.y, other.y)
        let sharesHorizontal = min(one.maxX, other.maxX) > max(one.x, other.x)
        return (sharesVertical && (one.maxX == other.x || other.maxX == one.x))
            || (sharesHorizontal && (one.maxY == other.y || other.maxY == one.y))
    }
}
