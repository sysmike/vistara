import AppKit
import Testing

@testable import RDPKit
@testable import RDPKitUI

/// Control-Tab in a session, which the Mac would take for Show Next Tab in a
/// tabbed window (#101).
@Suite
@MainActor
struct ControlTabTests {
    private final class Recorder {
        var events: [RDPInputEvent] = []
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

    private func press(_ code: UInt8) -> RDPInputEvent {
        .key(RDPScancode(code), isDown: true)
    }

    private func release(_ code: UInt8) -> RDPInputEvent {
        .key(RDPScancode(code), isDown: false)
    }

    /// Control-Tab and Control-Shift-Tab belong to the remote computer while
    /// the session has the keyboard, also as key equivalents (#101).
    @Test func controlTabGoesToTheRemoteComputer() throws {
        let view = RDPSessionView(framebuffer: RDPFramebuffer(), connectionName: "Build Server")
        let recorder = Recorder()
        view.inputHandler = { recorder.events.append(contentsOf: $0) }
        let controlTab = try key(.keyDown, keyCode: 0x30, characters: "\t", flags: .control)
        // Not in a window: not ours to handle.
        #expect(!view.takesControlTab(controlTab))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150), styleMask: [.titled], backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        let control = NSEvent.ModifierFlags(rawValue: 1 << 18 | 0x01)
        try view.flagsChanged(with: key(.flagsChanged, keyCode: 0x3B, flags: control))
        recorder.events.removeAll()

        #expect(view.performKeyEquivalent(with: controlTab))
        try view.keyUp(with: key(.keyUp, keyCode: 0x30, characters: "\t", flags: .control))
        let controlShiftTab = try key(.keyDown, keyCode: 0x30, characters: "\t", flags: [.control, .shift])
        #expect(view.takesControlTab(controlShiftTab))
        #expect(recorder.events == [press(0x0F), release(0x0F), press(0x0F)])

        // Plain Tab is a key press, not a key equivalent; Command-Tab is the Mac's.
        let tab = try key(.keyDown, keyCode: 0x30, characters: "\t")
        let commandTab = try key(.keyDown, keyCode: 0x30, characters: "\t", flags: [.command, .control])
        #expect(!view.takesControlTab(tab))
        #expect(!view.takesControlTab(commandTab))
        window.contentView = nil
    }
}
