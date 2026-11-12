import AppKit
import MetalKit
import RDPKit

/// Shows a session's remote desktop, scaled to fit the view.
///
/// The view draws only when the desktop changed or the view needs
/// redisplay; an idle session costs nothing. All drawing happens on the main
/// thread and never waits for the session thread.
public final class RDPSessionView: MTKView {
    /// Used in the accessibility label, for example "Remote desktop, Build Server".
    public var connectionName: String {
        didSet { setAccessibilityLabel(Self.accessibilityLabel(for: connectionName)) }
    }

    /// Receives what the user types, as input for the session. Key events
    /// are passed on and never logged.
    public var inputHandler: (([RDPInputEvent]) -> Void)?

    /// Sends Command-C, V, X, A, Z, F, S and Shift-Command-Z as their Control
    /// equivalents. When off, those shortcuts stay with the Mac like every
    /// other Command shortcut.
    public var translatesEditingShortcuts = true
    /// Right Command is the Windows key on the remote computer.
    public var rightCommandIsWindowsKey = false {
        didSet { translator.rightCommandIsWindowsKey = rightCommandIsWindowsKey }
    }

    /// Asks the remote computer to resize its desktop to fill this view
    /// whenever the view changes size or moves to another kind of display.
    /// When off, or when the server cannot resize, the desktop keeps its size
    /// and is scaled to fit.
    public var resizesDesktop = false {
        didSet { if resizesDesktop != oldValue { desktopSizeMayHaveChanged() } }
    }

    /// Gives the desktop every pixel of a Retina display. See `DesktopSize`.
    public var usesHiDPI = true {
        didSet { if usesHiDPI != oldValue { desktopSizeMayHaveChanged() } }
    }

    /// How long the view's size has to rest before the desktop follows.
    var resizeDelay = Duration.milliseconds(250)

    private var requestedDesktopSize: DesktopSize?
    private var pendingResize: Task<Void, Never>?

    var translator = KeyboardTranslator()
    var pointer = PointerTranslator()
    private var remoteCursor = RDPCursor.systemDefault
    var pointerTracking: NSTrackingArea?

    /// Number of frames drawn so far. For tests and diagnostics.
    public private(set) var drawCount = 0

    private let framebuffer: RDPFramebuffer
    private let renderer: FrameRenderer?
    private var observation: Task<Void, Never>?

    public init(framebuffer: RDPFramebuffer, connectionName: String) {
        self.framebuffer = framebuffer
        self.connectionName = connectionName
        let device = MTLCreateSystemDefaultDevice()
        renderer = device.flatMap { try? FrameRenderer(device: $0) }
        super.init(frame: .zero, device: device)

        colorPixelFormat = FrameRenderer.pixelFormat
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Remote desktops are sRGB. Declaring it lets the system match colours
        // on wide-gamut displays instead of oversaturating them.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Draw on demand only.
        isPaused = true
        enableSetNeedsDisplay = true

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(Self.accessibilityLabel(for: connectionName))
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("RDPSessionView is created in code")
    }

    static func accessibilityLabel(for connectionName: String) -> String {
        // Localization arrives with the app's string catalog.
        "Remote desktop, \(connectionName)"
    }

    /// The remote desktop's frame inside the view, in view coordinates.
    public var desktopFrame: CGRect {
        FitLayout.frame(content: desktopSize, container: bounds.size)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.cancel()
        observation = nil
        observeKeyWindow()
        guard let window else { return }
        // The desktop is the window's content, so typing goes to it.
        window.makeFirstResponder(self)
        desktopSizeMayHaveChanged()

        consumeUpdate()
        let changes = framebuffer.changes
        observation = Task { [weak self] in
            for await _ in changes {
                self?.consumeUpdate()
            }
        }
    }

    /// Uploads whatever changed and asks for one redraw.
    func consumeUpdate() {
        if let cursor = framebuffer.takeCursor() {
            showRemoteCursor(cursor)
        }
        // The first picture has arrived: now there is a desktop to resize.
        if resizesDesktop, requestedDesktopSize == nil, pendingResize == nil {
            desktopSizeMayHaveChanged()
        }
        guard let renderer, let update = framebuffer.takeUpdate() else { return }
        if renderer.apply(update) {
            needsDisplay = true
        }
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let renderer, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let commandBuffer = renderer.draw(pass: pass, targetSize: drawableSize)
        else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        drawCount += 1
    }

    // MARK: Desktop size

    /// The size that would fill this view now.
    var fillingDesktopSize: DesktopSize? {
        DesktopSize.filling(
            viewSize: bounds.size, backingScale: window?.backingScaleFactor ?? 1, usesHiDPI: usesHiDPI
        )
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        desktopSizeMayHaveChanged()
    }

    /// The window moved to a display with another pixel density.
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        desktopSizeMayHaveChanged()
    }

    /// Waits until the size has rested, then asks once. Meanwhile the
    /// picture is scaled, so the window resizes fluidly while the remote
    /// computer catches up.
    private func desktopSizeMayHaveChanged() {
        pendingResize?.cancel()
        pendingResize = nil
        guard resizesDesktop, window != nil else { return }
        let delay = resizeDelay
        pendingResize = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestDesktopSize()
        }
    }

    /// Asks for the size that fills the view, unless that was the last thing
    /// asked for. A server that answers with another size is not asked again
    /// until the view changes.
    func requestDesktopSize() {
        guard resizesDesktop, let size = fillingDesktopSize, size != requestedDesktopSize else { return }
        let current = framebuffer.size
        // Nothing to draw on yet: the session is not connected.
        guard current.width > 0 else { return }
        requestedDesktopSize = size
        if current.width == Int(size.width), current.height == Int(size.height), size.scalePercent == connectedScale {
            return
        }
        send([.desktopSize(width: size.width, height: size.height, scalePercent: size.scalePercent)])
    }

    /// The scale the session was connected with, so that a first request is
    /// not sent for what the desktop already is.
    public var connectedScale: UInt16 = 100

    /// Size of the remote desktop in its own pixels.
    var desktopSize: CGSize {
        let size = framebuffer.size
        return CGSize(width: size.width, height: size.height)
    }

    func send(_ events: [RDPInputEvent]) {
        guard !events.isEmpty else { return }
        inputHandler?(events)
    }

    // MARK: Cursor

    /// How large one remote pixel is drawn, in points.
    private var pointsPerPixel: CGFloat {
        let width = desktopSize.width
        return width > 0 ? desktopFrame.width / width : 1
    }

    /// The cursor shown over the desktop: the remote computer's, scaled like
    /// the desktop. Nil means the system's arrow.
    var desktopCursor: NSCursor? {
        CursorFactory.cursor(for: remoteCursor, pointsPerPixel: pointsPerPixel)
    }

    private func showRemoteCursor(_ cursor: RDPCursor) {
        remoteCursor = cursor
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        // Cursor rectangles take effect with the next move; a pointer that
        // rests over the desktop changes now.
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if window.isKeyWindow, desktopFrame.contains(location) {
            (desktopCursor ?? .arrow).set()
        }
    }

    /// The remote cursor applies over the desktop only. Beside it, and
    /// outside the view, the Mac's own cursor returns by itself.
    override public func resetCursorRects() {
        super.resetCursorRects()
        if let desktopCursor {
            addCursorRect(desktopFrame, cursor: desktopCursor)
        }
    }
}
