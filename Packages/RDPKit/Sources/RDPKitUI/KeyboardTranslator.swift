import RDPKit

/// Turns what the Mac keyboard does into what the remote keyboard should do,
/// and remembers which keys the remote computer believes are held, so none
/// stays stuck when the keyboard focus leaves.
///
/// The rules, from docs/DESIGN.md:
/// - Command belongs to the Mac and is never sent. Command shortcuts run the
///   Mac's menus, which is also how the keyboard is released from a session.
/// - Familiar editing shortcuts (Command-C, V, X, A, Z, F, S and
///   Shift-Command-Z) are sent as their Control equivalents.
/// - Everything else goes to the remote computer: Control, Option as Alt,
///   Shift, and every other key by its position.
public struct KeyboardTranslator: Sendable {
    public var keyboard: MacKeyboardKind

    /// Pressed keys by Mac key code, with what was sent for each.
    private var pressedKeys: [UInt16: RDPScancode] = [:]
    private var heldModifiers: [RDPScancode] = []

    public init(keyboard: MacKeyboardKind = .ansi) {
        self.keyboard = keyboard
    }

    /// True while the remote computer believes any key is held.
    public var hasKeysDown: Bool {
        !pressedKeys.isEmpty || !heldModifiers.isEmpty
    }

    /// A key went down, or repeats while held.
    public mutating func keyDown(keyCode: UInt16) -> [RDPInputEvent] {
        guard let scancode = pressedKeys[keyCode] ?? MacKeyMap.scancode(forKeyCode: keyCode, keyboard: keyboard)
        else { return [] }
        pressedKeys[keyCode] = scancode
        return [.key(scancode, isDown: true)]
    }

    /// A key went up. Keys whose press was not sent are ignored.
    public mutating func keyUp(keyCode: UInt16) -> [RDPInputEvent] {
        guard let scancode = pressedKeys.removeValue(forKey: keyCode) else { return [] }
        return [.key(scancode, isDown: false)]
    }

    /// The modifier keys changed. `flags` is the raw value of the event's
    /// modifier flags, which tells left from right. Sends only the difference
    /// to what is held, so a missed event corrects itself with the next one.
    public mutating func modifiersChanged(flags: UInt) -> [RDPInputEvent] {
        let wanted = Self.modifiers(in: flags)
        var events: [RDPInputEvent] = []
        for scancode in heldModifiers where !wanted.contains(scancode) {
            events.append(.key(scancode, isDown: false))
        }
        for scancode in wanted where !heldModifiers.contains(scancode) {
            events.append(.key(scancode, isDown: true))
        }
        heldModifiers = wanted
        return events
    }

    /// Caps Lock was switched on or off on the Mac: press it on the remote
    /// keyboard too.
    public func capsLockToggled() -> [RDPInputEvent] {
        RDPInputEvent.tap(.capsLock)
    }

    /// Command plus a key, sent as Control plus that key.
    public func editingShortcut(keyCode: UInt16) -> [RDPInputEvent] {
        guard let scancode = MacKeyMap.scancode(forKeyCode: keyCode, keyboard: keyboard) else { return [] }
        return [.key(.leftControl, isDown: true)] + RDPInputEvent.tap(scancode) + [.key(.leftControl, isDown: false)]
    }

    /// Releases everything the remote computer believes is held. Call this
    /// when the keyboard focus leaves the session.
    public mutating func releaseAll() -> [RDPInputEvent] {
        let scancodes = pressedKeys.keys.sorted().compactMap { pressedKeys[$0] } + heldModifiers
        pressedKeys.removeAll()
        heldModifiers.removeAll()
        return scancodes.map { .key($0, isDown: false) }
    }

    /// Whether Command plus this character, with or without Shift, is one of
    /// the editing shortcuts that are translated.
    public static func isEditingShortcut(characters: String, hasShift: Bool) -> Bool {
        let key = characters.lowercased()
        return hasShift ? key == "z" : ["c", "v", "x", "a", "z", "f", "s"].contains(key)
    }

    // MARK: Modifier flags

    // Device-independent flags, as in NSEvent.ModifierFlags.
    private static let shift: UInt = 1 << 17
    private static let control: UInt = 1 << 18
    private static let option: UInt = 1 << 19
    // Device-dependent flags that tell the left key from the right one.
    private static let leftControl: UInt = 0x0001
    private static let leftShift: UInt = 0x0002
    private static let rightShift: UInt = 0x0004
    private static let leftOption: UInt = 0x0020
    private static let rightOption: UInt = 0x0040
    private static let rightControl: UInt = 0x2000

    private static func modifiers(in flags: UInt) -> [RDPScancode] {
        side(flags, any: control, left: leftControl, right: rightControl, keys: (.leftControl, .rightControl))
            + side(flags, any: shift, left: leftShift, right: rightShift, keys: (.leftShift, .rightShift))
            + side(flags, any: option, left: leftOption, right: rightOption, keys: (.leftAlt, .rightAlt))
    }

    /// The keys of one modifier that are down. Events that do not say which
    /// side, such as synthetic ones, count as the left key.
    private static func side(
        _ flags: UInt, any: UInt, left: UInt, right: UInt, keys: (left: RDPScancode, right: RDPScancode)
    ) -> [RDPScancode] {
        guard flags & any != 0 else { return [] }
        var down: [RDPScancode] = []
        if flags & left != 0 { down.append(keys.left) }
        if flags & right != 0 { down.append(keys.right) }
        return down.isEmpty ? [keys.left] : down
    }
}
