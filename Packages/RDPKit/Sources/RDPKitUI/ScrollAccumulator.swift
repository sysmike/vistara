import CoreGraphics
import RDPKit

/// Collects scroll deltas and hands them out as wheel turns.
///
/// A trackpad reports many small distances; the remote computer counts in
/// wheel units, 120 to a notch. Turns are sent a quarter notch at a time:
/// programs that scroll smoothly follow the fingers, and the others add the
/// quarters up to whole notches, as Windows expects them to.
///
/// macOS has already applied the natural scrolling setting to the deltas, so
/// the remote content moves the way local content does.
struct ScrollAccumulator {
    struct Turn: Equatable {
        var axis: RDPWheelAxis
        var rotation: Int16
    }

    /// Wheel units for one point of trackpad travel: 40 points make a notch.
    static let unitsPerPoint = 3.0
    /// Wheel units for one line of a mouse wheel.
    static let unitsPerLine = 120.0
    static let step = 30
    /// The most one event can carry, in whole steps.
    static let largestTurn = 240

    private var vertical = 0.0
    private var horizontal = 0.0

    /// Adds what a scroll event reported. `isPrecise` is true for trackpads,
    /// whose deltas are points, and false for wheels, whose deltas are lines.
    mutating func add(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> [Turn] {
        let scale = isPrecise ? Self.unitsPerPoint : Self.unitsPerLine
        // Content that moves down means the wheel turned up, which is
        // positive for both systems. Horizontally the two disagree.
        vertical += Double(deltaY) * scale
        horizontal -= Double(deltaX) * scale
        return Self.turns(from: &vertical, axis: .vertical) + Self.turns(from: &horizontal, axis: .horizontal)
    }

    /// Forgets partial turns, for the start of a new gesture.
    mutating func reset() {
        vertical = 0
        horizontal = 0
    }

    private static func turns(from pending: inout Double, axis: RDPWheelAxis) -> [Turn] {
        guard pending.isFinite else {
            pending = 0
            return []
        }
        // Whole steps only; the remainder waits for the next event. A burst
        // is cut off rather than replayed long after the fingers stopped.
        var units = Int((pending / Double(step)).rounded(.towardZero)) * step
        pending -= Double(units)
        units = min(max(units, -4 * largestTurn), 4 * largestTurn)

        var turns: [Turn] = []
        while units != 0 {
            let part = min(max(units, -largestTurn), largestTurn)
            turns.append(Turn(axis: axis, rotation: Int16(part)))
            units -= part
        }
        return turns
    }
}
