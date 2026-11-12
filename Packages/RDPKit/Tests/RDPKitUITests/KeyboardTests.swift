import AppKit
import Testing

@testable import RDPKit
@testable import RDPKitUI

private func press(_ code: UInt8, extended: Bool = false) -> RDPInputEvent {
    .key(RDPScancode(code, extended: extended), isDown: true)
}

private func release(_ code: UInt8, extended: Bool = false) -> RDPInputEvent {
    .key(RDPScancode(code, extended: extended), isDown: false)
}

// Raw modifier flags as macOS reports them: the general flag plus the bit
// for the left or right key.
private let leftShiftFlags: UInt = 1 << 17 | 0x02
private let rightShiftFlags: UInt = 1 << 17 | 0x04
private let leftControlFlags: UInt = 1 << 18 | 0x01
private let rightControlFlags: UInt = 1 << 18 | 0x2000
private let leftOptionFlags: UInt = 1 << 19 | 0x20
private let rightOptionFlags: UInt = 1 << 19 | 0x40
private let leftCommandFlags: UInt = 1 << 20 | 0x08

@Suite
struct MacKeyMapTests {
    private func code(_ keyCode: UInt16, _ keyboard: MacKeyboardKind = .ansi) -> RDPScancode? {
        MacKeyMap.scancode(forKeyCode: keyCode, keyboard: keyboard)
    }

    @Test func lettersFollowTheirPositionOnAUSKeyboard() {
        // Mac key codes for A to Z, and the scancodes of the same keys.
        let keyCodes: [UInt16] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06
        ]
        let scancodes: [UInt8] = [
            0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
            0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C
        ]
        #expect(Set(scancodes).count == 26)
        for (keyCode, scancode) in zip(keyCodes, scancodes) {
            #expect(code(keyCode) == RDPScancode(scancode), "key code \(keyCode)")
        }
    }

    @Test func digitsRunFromOneToZero() {
        let keyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (index, keyCode) in keyCodes.enumerated() {
            #expect(code(keyCode) == RDPScancode(UInt8(0x02 + index)), "digit key \(index + 1)")
        }
    }

    @Test func functionKeys() {
        let keyCodes: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D]
        for (index, keyCode) in keyCodes.enumerated() {
            #expect(code(keyCode) == RDPScancode(UInt8(0x3B + index)), "F\(index + 1)")
        }
        #expect(code(0x67) == RDPScancode(0x57))  // F11
        #expect(code(0x6F) == RDPScancode(0x58))  // F12
        // F13 and F14 sit where a PC has Print Screen and Scroll Lock.
        #expect(code(0x69) == RDPScancode(0x37, extended: true))
        #expect(code(0x6B) == RDPScancode(0x46))
    }

    @Test func arrowsAndNavigationKeysAreExtended() {
        #expect(code(0x7B) == RDPScancode(0x4B, extended: true))  // left
        #expect(code(0x7C) == RDPScancode(0x4D, extended: true))  // right
        #expect(code(0x7D) == RDPScancode(0x50, extended: true))  // down
        #expect(code(0x7E) == RDPScancode(0x48, extended: true))  // up
        #expect(code(0x73) == RDPScancode(0x47, extended: true))  // Home
        #expect(code(0x77) == RDPScancode(0x4F, extended: true))  // End
        #expect(code(0x74) == RDPScancode(0x49, extended: true))  // Page Up
        #expect(code(0x79) == RDPScancode(0x51, extended: true))  // Page Down
        #expect(code(0x75) == RDPScancode.delete)  // Forward Delete
        #expect(code(0x33) == RDPScancode(0x0E))  // Delete is Backspace
    }

    @Test func keypadTypesDigitsAndSharesNoCodeWithTheArrows() {
        let keyCodes: [UInt16] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
        let scancodes: [UInt8] = [0x52, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49]
        for (keyCode, scancode) in zip(keyCodes, scancodes) {
            #expect(code(keyCode) == RDPScancode(scancode), "keypad key code \(keyCode)")
        }
        #expect(code(0x4C) == RDPScancode(0x1C, extended: true))  // Enter
        #expect(code(0x4B) == RDPScancode(0x35, extended: true))  // divide
        #expect(code(0x43) == RDPScancode(0x37))  // multiply
        #expect(code(0x45) == RDPScancode(0x4E))  // plus
        #expect(code(0x4E) == RDPScancode(0x4A))  // minus
        #expect(code(0x41) == RDPScancode(0x53))  // decimal
        // Clear would switch Num Lock off on the remote computer.
        #expect(code(0x47) == nil)
    }

    @Test func modifierKeysAreNotInTheMap() {
        for keyCode: UInt16 in 0x36...0x3F {
            #expect(code(keyCode) == nil, "key code \(keyCode)")
        }
    }

    @Test func isoKeyboardsSwapTheTwoKeysMacOSReportsSwapped() {
        // ANSI: the key left of 1.
        #expect(code(0x32, .ansi) == RDPScancode(0x29))
        // ISO: the key left of 1 reports as "section", the extra key next to
        // the left Shift key as "grave".
        #expect(code(0x0A, .iso) == RDPScancode(0x29))
        #expect(code(0x32, .iso) == RDPScancode(0x56))
    }

    @Test func jisKeyboardsHaveTheirExtraKeys() {
        #expect(code(0x32, .jis) == RDPScancode(0x29))
        #expect(code(0x5D, .jis) == RDPScancode(0x7D))  // Yen
        #expect(code(0x5E, .jis) == RDPScancode(0x73))  // underscore
        #expect(code(0x66, .jis) == RDPScancode(0x7B))  // Eisu
        #expect(code(0x68, .jis) == RDPScancode(0x79))  // Kana
    }

    @Test func noTwoKeysShareAScancode() {
        for keyboard in [MacKeyboardKind.ansi, .iso, .jis] {
            var seen: [RDPScancode: UInt16] = [:]
            for keyCode: UInt16 in 0...0x7F {
                guard let scancode = code(keyCode, keyboard) else { continue }
                #expect(seen[scancode] == nil, "key codes \(seen[scancode] ?? 0) and \(keyCode)")
                seen[scancode] = keyCode
            }
        }
    }
}

@Suite
struct KeyboardTranslatorTests {
    @Test func aKeyGoesDownRepeatsAndComesUp() {
        var translator = KeyboardTranslator()
        #expect(translator.keyDown(keyCode: 0x00) == [press(0x1E)])
        #expect(translator.keyDown(keyCode: 0x00) == [press(0x1E)])
        #expect(translator.keyUp(keyCode: 0x00) == [release(0x1E)])
        #expect(!translator.hasKeysDown)
    }

    @Test func aReleaseWithoutAPressIsNotSent() {
        var translator = KeyboardTranslator()
        #expect(translator.keyUp(keyCode: 0x00).isEmpty)
        #expect(translator.keyDown(keyCode: 0x47).isEmpty)  // not in the map
    }

    @Test func modifiersKnowLeftFromRight() {
        var translator = KeyboardTranslator()
        #expect(translator.modifiersChanged(flags: leftShiftFlags) == [press(0x2A)])
        #expect(translator.modifiersChanged(flags: leftShiftFlags | rightShiftFlags) == [press(0x36)])
        #expect(translator.modifiersChanged(flags: rightShiftFlags) == [release(0x2A)])
        #expect(translator.modifiersChanged(flags: 0) == [release(0x36)])

        #expect(translator.modifiersChanged(flags: rightControlFlags) == [press(0x1D, extended: true)])
        #expect(translator.modifiersChanged(flags: leftControlFlags) == [release(0x1D, extended: true), press(0x1D)])
        #expect(translator.modifiersChanged(flags: 0) == [release(0x1D)])
    }

    @Test func optionIsAltAndRightOptionIsAltGr() {
        var translator = KeyboardTranslator()
        #expect(translator.modifiersChanged(flags: leftOptionFlags) == [press(0x38)])
        #expect(translator.modifiersChanged(flags: rightOptionFlags) == [release(0x38), press(0x38, extended: true)])
    }

    @Test func commandIsNeverSent() {
        var translator = KeyboardTranslator()
        #expect(translator.modifiersChanged(flags: leftCommandFlags).isEmpty)
        #expect(!translator.hasKeysDown)
    }

    @Test func aModifierWithoutASideCountsAsTheLeftKey() {
        var translator = KeyboardTranslator()
        #expect(translator.modifiersChanged(flags: 1 << 18) == [press(0x1D)])
    }

    @Test func repeatedFlagsSendNothingNew() {
        var translator = KeyboardTranslator()
        _ = translator.modifiersChanged(flags: leftShiftFlags)
        #expect(translator.modifiersChanged(flags: leftShiftFlags).isEmpty)
    }

    @Test func nothingStaysStuckWhenTheFocusLeaves() {
        var translator = KeyboardTranslator()
        _ = translator.modifiersChanged(flags: leftControlFlags | leftShiftFlags)
        _ = translator.keyDown(keyCode: 0x00)
        _ = translator.keyDown(keyCode: 0x7B)
        #expect(translator.hasKeysDown)

        let released = translator.releaseAll()
        #expect(Set(released) == [release(0x1E), release(0x4B, extended: true), release(0x1D), release(0x2A)])
        #expect(released.count == 4)
        #expect(!translator.hasKeysDown)
        // The keys come up on the Mac later, somewhere else: nothing to send.
        #expect(translator.keyUp(keyCode: 0x00).isEmpty)
        #expect(translator.releaseAll().isEmpty)
    }

    @Test func aKeyKeepsItsScancodeUntilItComesUp() {
        var translator = KeyboardTranslator(keyboard: .ansi)
        _ = translator.keyDown(keyCode: 0x32)
        translator.keyboard = .iso
        #expect(translator.keyUp(keyCode: 0x32) == [release(0x29)])
    }

    @Test func editingShortcutsBecomeControlShortcuts() {
        let translator = KeyboardTranslator()
        #expect(translator.editingShortcut(keyCode: 0x08) == [press(0x1D), press(0x2E), release(0x2E), release(0x1D)])
        #expect(translator.editingShortcut(keyCode: 0x47).isEmpty)

        for key in ["c", "v", "x", "a", "z", "f", "s", "C"] {
            #expect(KeyboardTranslator.isEditingShortcut(characters: key, hasShift: false), "\(key)")
        }
        #expect(KeyboardTranslator.isEditingShortcut(characters: "Z", hasShift: true))
        for key in ["w", "q", "n", "0", "`", "", "cv"] {
            #expect(!KeyboardTranslator.isEditingShortcut(characters: key, hasShift: false), "\(key)")
        }
        #expect(!KeyboardTranslator.isEditingShortcut(characters: "c", hasShift: true))
    }

    @Test func capsLockIsPressedAndReleased() {
        #expect(KeyboardTranslator().capsLockToggled() == [press(0x3A), release(0x3A)])
    }

    // Command and the device bit for the right Command key.
    private static let rightCommand: UInt = (1 << 20) | 0x0010
    private static let leftCommand: UInt = (1 << 20) | 0x0008

    @Test func rightCommandIsTheWindowsKeyOnlyWhenChosen() {
        var mac = KeyboardTranslator()
        #expect(mac.modifiersChanged(flags: Self.rightCommand).isEmpty)
        #expect(!mac.isWindowsCombination(flags: Self.rightCommand))

        var windows = KeyboardTranslator(rightCommandIsWindowsKey: true)
        #expect(windows.modifiersChanged(flags: Self.rightCommand) == [press(0x5C, extended: true)])
        #expect(windows.isWindowsCombination(flags: Self.rightCommand))
        #expect(windows.modifiersChanged(flags: 0) == [release(0x5C, extended: true)])
        // Left Command stays with the Mac, also together with the right one.
        #expect(windows.modifiersChanged(flags: Self.leftCommand).isEmpty)
        #expect(!windows.isWindowsCombination(flags: Self.leftCommand | Self.rightCommand))
    }

    @Test func aKeyWithTheWindowsKeyIsPressedAndReleased() {
        let windows = KeyboardTranslator(rightCommandIsWindowsKey: true)
        // R, by position.
        #expect(windows.windowsCombination(keyCode: 0x0F) == [press(0x13), release(0x13)])
    }
}

@Suite(.serialized)
@MainActor
struct SessionViewKeyboardTests {
    private final class Recorder {
        var events: [RDPInputEvent] = []
    }

    private func makeView() -> (view: RDPSessionView, recorder: Recorder) {
        let view = RDPSessionView(framebuffer: RDPFramebuffer(), connectionName: "Build Server")
        let recorder = Recorder()
        view.inputHandler = { recorder.events.append(contentsOf: $0) }
        return (view, recorder)
    }

    private func key(
        _ type: NSEvent.EventType, keyCode: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )
        )
    }

    @Test func theViewTakesTheKeyboard() {
        let (view, _) = makeView()
        #expect(view.acceptsFirstResponder)
    }

    @Test func keysAreSentByPosition() throws {
        let (view, recorder) = makeView()
        try view.keyDown(with: key(.keyDown, keyCode: 0x00, characters: "a"))
        try view.keyUp(with: key(.keyUp, keyCode: 0x00, characters: "a"))
        // Tab goes to the remote computer instead of moving the Mac's focus.
        try view.keyDown(with: key(.keyDown, keyCode: 0x30, characters: "\t"))
        #expect(recorder.events == [press(0x1E), release(0x1E), press(0x0F)])
    }

    @Test func keysPressedWithCommandStayOnTheMac() throws {
        let (view, recorder) = makeView()
        try view.keyDown(with: key(.keyDown, keyCode: 0x0D, characters: "w", flags: .command))
        try view.keyUp(with: key(.keyUp, keyCode: 0x0D, characters: "w", flags: .command))
        #expect(recorder.events.isEmpty)
    }

    @Test func modifierChangesAreSent() throws {
        let (view, recorder) = makeView()
        let shift = NSEvent.ModifierFlags(rawValue: leftShiftFlags)
        try view.flagsChanged(with: key(.flagsChanged, keyCode: 0x38, flags: shift))
        try view.flagsChanged(with: key(.flagsChanged, keyCode: 0x38))
        try view.flagsChanged(with: key(.flagsChanged, keyCode: 0x39, flags: .capsLock))
        #expect(recorder.events == [press(0x2A), release(0x2A), press(0x3A), release(0x3A)])
    }

    @Test func losingTheKeyboardReleasesWhatIsHeld() throws {
        let (view, recorder) = makeView()
        let control = NSEvent.ModifierFlags(rawValue: leftControlFlags)
        try view.flagsChanged(with: key(.flagsChanged, keyCode: 0x3B, flags: control))
        try view.keyDown(with: key(.keyDown, keyCode: 0x00, characters: "a", flags: control))
        recorder.events.removeAll()

        #expect(view.resignFirstResponder())
        #expect(Set(recorder.events) == [release(0x1E), release(0x1D)])
    }

    @Test func gettingTheKeyboardStatesTheLocksFirst() {
        let (view, recorder) = makeView()
        view.keyboardFocusArrived()
        guard case .lockState(let locks) = recorder.events.first else {
            Issue.record("expected the lock state first, got \(recorder.events)")
            return
        }
        #expect(locks.contains(.numLock))
    }

    @Test func editingShortcutsAreTranslatedOnlyWhenTheViewHasTheKeyboard() throws {
        let (view, recorder) = makeView()
        let copy = try key(.keyDown, keyCode: 0x08, characters: "c", flags: .command)
        // Not in a window: not ours to handle.
        #expect(!view.performKeyEquivalent(with: copy))
        #expect(recorder.events.isEmpty)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.titled], backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        #expect(window.firstResponder === view)
        recorder.events.removeAll()

        #expect(view.performKeyEquivalent(with: copy))
        #expect(recorder.events == [press(0x1D), press(0x2E), release(0x2E), release(0x1D)])
        recorder.events.removeAll()

        // Command-W and the rest of the menu bar stay with the Mac.
        let close = try key(.keyDown, keyCode: 0x0D, characters: "w", flags: .command)
        #expect(!view.performKeyEquivalent(with: close))
        // So does Command-C once translation is switched off.
        view.translatesEditingShortcuts = false
        #expect(!view.performKeyEquivalent(with: copy))
        #expect(recorder.events.isEmpty)
        window.contentView = nil
    }

    @Test func rightCommandShortcutsGoToTheRemoteComputerWhenItIsTheWindowsKey() throws {
        let (view, recorder) = makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.titled], backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        recorder.events.removeAll()
        let rightCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0010)
        let windowsR = try key(.keyDown, keyCode: 0x0F, characters: "r", flags: rightCommand)

        // By default, Command belongs to the Mac.
        #expect(!view.performKeyEquivalent(with: windowsR))
        #expect(recorder.events.isEmpty)

        view.rightCommandIsWindowsKey = true
        #expect(view.performKeyEquivalent(with: windowsR))
        #expect(recorder.events == [press(0x13), release(0x13)])
        window.contentView = nil
    }
}
