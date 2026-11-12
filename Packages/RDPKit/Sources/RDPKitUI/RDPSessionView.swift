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
        FitLayout.frame(content: renderer?.desktopSize ?? .zero, container: bounds.size)
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
}
