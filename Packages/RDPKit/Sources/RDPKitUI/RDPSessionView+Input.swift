import AppKit
import RDPKit

/// Keyboard and pointer input for the session view. Key events are passed
/// on and never logged.
extension RDPSessionView {
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

    /// Control-Tab and Control-Shift-Tab, while the session has the keyboard,
    /// go to the remote computer, where Windows apps switch their own tabs
    /// with them. In a tabbed window the Mac's Window menu would take them for
    /// Show Next Tab, so the window asks here before its menus do
    /// (docs/DESIGN.md, Keyboard). The key's release arrives as usual.
    public func takesControlTab(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard event.type == .keyDown, event.keyCode == Self.tabKeyCode, window?.firstResponder === self,
            modifiers.contains(.control), !modifiers.contains(.command)
        else { return false }
        send(translator.keyDown(keyCode: event.keyCode))
        return true
    }

    static let tabKeyCode: UInt16 = 0x30

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if takesControlTab(event) { return true }
        // Right Command as the Windows key: Windows-R, Windows-E and the
        // rest go to the remote computer, not to the Mac's menus.
        if event.type == .keyDown, window?.firstResponder === self,
            translator.isWindowsCombination(flags: event.modifierFlags.rawValue) {
            send(translator.windowsCombination(keyCode: event.keyCode))
            return true
        }
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

    /// The session has the keyboard again: state the lock keys, which also
    /// makes the server forget every key it thought was held, then send the
    /// modifiers that are down right now.
    func keyboardFocusArrived() {
        translator = KeyboardTranslator(
            keyboard: MacKeyboard.current, rightCommandIsWindowsKey: rightCommandIsWindowsKey
        )
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

    func observeKeyWindow() {
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
}
