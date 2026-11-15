import AppKit
import RDPKit

/// The Mac window of one remote program window (docs/DESIGN.md, RemoteApp):
/// no title bar of its own, since the program draws its own frame. While the
/// remote computer moves or resizes it for the user, the window follows the
/// pointer itself and keeps the pointer's events from the remote computer.
final class ProgramWindow: NSWindow {
    /// Menus, lists that drop down, and tooltips never take the keyboard.
    var takesKeyboard = true
    /// Asked to close, as File > Close does: the program decides.
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?

    /// A move or resize the Mac carries out for the remote computer.
    struct LocalDrag {
        var kind: RDPMoveSizeKind
        /// Where the pointer was pressed, and the window's frame then, on the screen.
        var start: CGPoint
        var startFrame: CGRect
    }

    private(set) var localDrag: LocalDrag?
    /// The drag ended with the pointer let go there, on the screen.
    var onLocalDragEnded: ((CGPoint) -> Void)?

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { takesKeyboard }

    override func performClose(_ sender: Any?) {
        onClose?()
    }

    override func performMiniaturize(_ sender: Any?) {
        onMinimize?()
    }

    func beginLocalDrag(_ kind: RDPMoveSizeKind, at start: CGPoint) {
        localDrag = LocalDrag(kind: kind, start: start, startFrame: frame)
    }

    /// Ends a drag that is still going, as when the remote computer ended it.
    func endLocalDrag() {
        localDrag = nil
    }

    override func sendEvent(_ event: NSEvent) {
        guard let drag = localDrag else {
            super.sendEvent(event)
            return
        }
        let point = convertPoint(toScreen: event.locationInWindow)
        switch event.type {
        case .leftMouseDragged:
            setFrame(Self.frame(for: drag, pointer: point, minSize: minSize, maxSize: maxSize), display: true)
        case .leftMouseUp:
            localDrag = nil
            onLocalDragEnded?(point)
        default:
            super.sendEvent(event)
        }
    }

    /// The frame for the pointer at `pointer`: moved by as much as it went,
    /// or with the dragged edges following it, within the size limits.
    static func frame(for drag: LocalDrag, pointer: CGPoint, minSize: CGSize, maxSize: CGSize) -> CGRect {
        let dx = pointer.x - drag.start.x
        let dy = pointer.y - drag.start.y
        var frame = drag.startFrame
        switch drag.kind {
        case .move:
            frame = frame.offsetBy(dx: dx, dy: dy)
        case .keyboardMove, .keyboardSize:
            break
        default:
            let edges = edges(of: drag.kind)
            var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
            if edges.left { minX = min(minX + dx, maxX - minSize.width) }
            if edges.right { maxX = max(maxX + dx, minX + minSize.width) }
            // Remote "top" is the Mac's larger y.
            if edges.top { maxY = max(maxY + dy, minY + minSize.height) }
            if edges.bottom { minY = min(minY + dy, maxY - minSize.height) }
            frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            frame.size.width = min(frame.width, maxSize.width)
            frame.size.height = min(frame.height, maxSize.height)
        }
        return frame
    }

    private struct Edges {
        var left = false, right = false, top = false, bottom = false
    }

    private static func edges(of kind: RDPMoveSizeKind) -> Edges {
        switch kind {
        case .left: Edges(left: true)
        case .right: Edges(right: true)
        case .top: Edges(top: true)
        case .bottom: Edges(bottom: true)
        case .topLeft: Edges(left: true, top: true)
        case .topRight: Edges(right: true, top: true)
        case .bottomLeft: Edges(left: true, bottom: true)
        case .bottomRight: Edges(right: true, bottom: true)
        case .move, .keyboardMove, .keyboardSize: Edges()
        }
    }
}
