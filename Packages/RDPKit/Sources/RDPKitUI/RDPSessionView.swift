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

    private var translator = KeyboardTranslator()
    private var pointer = PointerTranslator()
    private var remoteCursor = RDPCursor.systemDefault
    private var pointerTracking: NSTrackingArea?

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

    // MARK: Keyboard

    override public var acceptsFirstResponder: Bool { true }

    override public func becomeFirstResponder() -> Bool {
        if window?.isKeyWindow == true { keyboardFocusArrived() }
        return true
    }

    override public func resignFirstResponder() -> Bool {
        keyboardFocusLeft()
        return true
    }

    override public func keyDown(with event: NSEvent) {
        // Command belongs to the Mac. Not calling super also keeps Tab and
        // the other keys AppKit would act on going to the remote computer.
        guard !event.modifierFlags.contains(.command) else { return }
        send(translator.keyDown(keyCode: event.keyCode))
    }

    override public func keyUp(with event: NSEvent) {
        send(translator.keyUp(keyCode: event.keyCode))
    }

    override public func flagsChanged(with event: NSEvent) {
        if event.keyCode == MacKeyMap.capsLockKeyCode {
            send(translator.capsLockToggled())
        } else {
            send(translator.modifiersChanged(flags: event.modifierFlags.rawValue))
        }
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard translatesEditingShortcuts, event.type == .keyDown, window?.firstResponder === self,
            modifiers == .command || modifiers == [.command, .shift],
            KeyboardTranslator.isEditingShortcut(
                characters: event.charactersIgnoringModifiers ?? "", hasShift: modifiers.contains(.shift)
            )
        else { return super.performKeyEquivalent(with: event) }
        send(translator.editingShortcut(keyCode: event.keyCode))
        return true
    }

    private func send(_ events: [RDPInputEvent]) {
        guard !events.isEmpty else { return }
        inputHandler?(events)
    }

    /// The session has the keyboard again: state the lock keys, which also
    /// makes the server forget every key it thought was held, then send the
    /// modifiers that are down right now.
    func keyboardFocusArrived() {
        translator = KeyboardTranslator(keyboard: MacKeyboard.current)
        let flags = NSEvent.modifierFlags
        // A Mac has no Num Lock; the keypad always types digits.
        let locks: RDPLockState = flags.contains(.capsLock) ? [.numLock, .capsLock] : .numLock
        send([.lockState(locks)] + translator.modifiersChanged(flags: flags.rawValue))
    }

    /// The keyboard went elsewhere: release what is held, so that nothing
    /// stays stuck on the remote computer.
    func keyboardFocusLeft() {
        send(translator.releaseAll())
        send(pointer.releaseButtons())
    }

    private func observeKeyWindow() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(
            self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window
        )
        center.addObserver(
            self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window
        )
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === self { keyboardFocusArrived() }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        keyboardFocusLeft()
    }

    // MARK: Pointer

    /// Size of the remote desktop in its own pixels.
    private var desktopSize: CGSize {
        let size = framebuffer.size
        return CGSize(width: size.width, height: size.height)
    }

    private var geometry: PointerTranslator.Geometry {
        PointerTranslator.Geometry(viewSize: bounds.size, desktopSize: desktopSize)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        // Moves are followed only in the key window, like any Mac window.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        pointerTracking = area
    }

    override public func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override public func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    override public func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    override public func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    override public func mouseDown(with event: NSEvent) { button(.left, isDown: true, event) }
    override public func mouseUp(with event: NSEvent) { button(.left, isDown: false, event) }
    override public func rightMouseDown(with event: NSEvent) { button(.right, isDown: true, event) }
    override public func rightMouseUp(with event: NSEvent) { button(.right, isDown: false, event) }

    override public func otherMouseDown(with event: NSEvent) {
        guard let which = Self.otherButton(event.buttonNumber) else { return }
        button(which, isDown: true, event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard let which = Self.otherButton(event.buttonNumber) else { return }
        button(which, isDown: false, event)
    }

    override public func scrollWheel(with event: NSEvent) {
        let delta = PointerTranslator.ScrollDelta(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            startsGesture: event.phase.contains(.began)
        )
        send(pointer.scrolled(delta, at: location(of: event), in: geometry))
    }

    /// The third button is the middle one; the next two are back and forward.
    static func otherButton(_ buttonNumber: Int) -> RDPPointerButton? {
        switch buttonNumber {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func pointerMoved(_ event: NSEvent) {
        send(pointer.moved(to: location(of: event), in: geometry))
    }

    private func button(_ button: RDPPointerButton, isDown: Bool, _ event: NSEvent) {
        send(pointer.button(button, isDown: isDown, at: location(of: event), in: geometry))
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
