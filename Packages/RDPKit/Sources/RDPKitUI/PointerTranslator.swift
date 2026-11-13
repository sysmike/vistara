import CoreGraphics
import RDPKit

/// Turns what the Mac's pointer does over the view into pointer input for
/// the remote computer, and remembers which buttons the remote computer
/// believes are held.
struct PointerTranslator {
    /// Where the desktop is shown: the view's size in points and the
    /// desktop's size in its own pixels.
    struct Geometry {
        var viewSize: CGSize
        /// The part of the desktop the view shows, in the desktop's pixels:
        /// all of it, unless the view shows one display's region of a
        /// desktop across several (docs/DESIGN.md, Multiple displays).
        var desktopSize: CGSize
        var origin: CGPoint = .zero
    }

    struct ScrollDelta {
        var x: CGFloat
        var y: CGFloat
        /// True for trackpads, whose deltas are points; false for wheels,
        /// whose deltas are lines.
        var isPrecise: Bool
        var startsGesture = false
    }

    private var heldButtons: Set<RDPPointerButton> = []
    private var lastPosition: DesktopPoint?
    private var scroll = ScrollAccumulator()

    /// The pointer is at a point of the view. Beside the desktop this is
    /// ignored, unless a button is held: a drag keeps going along the edge.
    mutating func moved(to point: CGPoint, in geometry: Geometry) -> [RDPInputEvent] {
        guard let position = position(at: point, in: geometry, clamped: !heldButtons.isEmpty),
            position != lastPosition
        else { return [] }
        lastPosition = position
        return [.pointerMove(x: position.x, y: position.y)]
    }

    /// A button went down or up at a point of the view. A press beside the
    /// desktop is ignored, and so is the release that belongs to it.
    mutating func button(
        _ button: RDPPointerButton, isDown: Bool, at point: CGPoint, in geometry: Geometry
    ) -> [RDPInputEvent] {
        if isDown {
            guard let position = position(at: point, in: geometry, clamped: false) else { return [] }
            heldButtons.insert(button)
            lastPosition = position
            return [.pointerButton(button, isDown: true, x: position.x, y: position.y)]
        }
        guard heldButtons.remove(button) != nil,
            let position = position(at: point, in: geometry, clamped: true) ?? lastPosition
        else { return [] }
        lastPosition = position
        return [.pointerButton(button, isDown: false, x: position.x, y: position.y)]
    }

    /// The wheel or trackpad scrolled while the pointer was at a point of the view.
    mutating func scrolled(_ delta: ScrollDelta, at point: CGPoint, in geometry: Geometry) -> [RDPInputEvent] {
        if delta.startsGesture { scroll.reset() }
        guard let position = position(at: point, in: geometry, clamped: false) else { return [] }
        return scroll.add(deltaX: delta.x, deltaY: delta.y, isPrecise: delta.isPrecise).map {
            .wheel($0.axis, rotation: $0.rotation, x: position.x, y: position.y)
        }
    }

    /// Releases the buttons the remote computer believes are held. Call this
    /// when the session loses the user's attention.
    mutating func releaseButtons() -> [RDPInputEvent] {
        let held = RDPPointerButton.allCases.filter { heldButtons.contains($0) }
        heldButtons.removeAll()
        guard let position = lastPosition else { return [] }
        return held.map { .pointerButton($0, isDown: false, x: position.x, y: position.y) }
    }

    private func position(at point: CGPoint, in geometry: Geometry, clamped: Bool) -> DesktopPoint? {
        guard let local = PointerMapper.desktopPoint(
            at: point, viewSize: geometry.viewSize, desktopSize: geometry.desktopSize, clamped: clamped
        ) else { return nil }
        let x = min(max(CGFloat(local.x) + geometry.origin.x, 0), CGFloat(UInt16.max))
        let y = min(max(CGFloat(local.y) + geometry.origin.y, 0), CGFloat(UInt16.max))
        return DesktopPoint(x: UInt16(x), y: UInt16(y))
    }
}
