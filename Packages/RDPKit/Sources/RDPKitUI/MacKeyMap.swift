import RDPKit

/// The physical shape of a Mac keyboard. It decides a few keys that differ
/// between regions.
public enum MacKeyboardKind: Sendable {
    case ansi
    case iso
    case jis
}

/// Translates macOS virtual key codes, which name key positions, to RDP
/// scancodes, which also name key positions. The Mac input source plays no
/// part: the remote computer's keyboard layout decides what a key types.
///
/// Modifier keys are not in this map; `KeyboardTranslator` handles them from
/// the modifier flags.
public enum MacKeyMap {
    /// The key left of 1 on ANSI and JIS keyboards, and next to the left
    /// Shift key on ISO keyboards.
    static let graveKeyCode: UInt16 = 0x32
    /// Only on ISO keyboards: the key left of 1.
    static let sectionKeyCode: UInt16 = 0x0A
    static let capsLockKeyCode: UInt16 = 0x39

    public static func scancode(forKeyCode keyCode: UInt16, keyboard: MacKeyboardKind) -> RDPScancode? {
        // On ISO keyboards macOS reports these two keys the other way round
        // from where they sit.
        switch (keyCode, keyboard) {
        case (graveKeyCode, .iso): return RDPScancode(0x56)
        case (sectionKeyCode, .iso): return RDPScancode(0x29)
        case (graveKeyCode, _): return RDPScancode(0x29)
        case (sectionKeyCode, _): return RDPScancode(0x56)
        default: break
        }
        if let code = plain[keyCode] { return RDPScancode(code) }
        if let code = extended[keyCode] { return RDPScancode(code, extended: true) }
        return nil
    }

    private static let plain: [UInt16: UInt8] = {
        var map: [UInt16: UInt8] = [:]
        map.merge(letters) { first, _ in first }
        map.merge(digitsAndPunctuation) { first, _ in first }
        map.merge(functionKeys) { first, _ in first }
        map.merge(keypad) { first, _ in first }
        map.merge(japanese) { first, _ in first }
        return map
    }()

    private static let letters: [UInt16: UInt8] = [
        0x00: 0x1E, 0x0B: 0x30, 0x08: 0x2E, 0x02: 0x20, 0x0E: 0x12, 0x03: 0x21, 0x05: 0x22,  // A–G
        0x04: 0x23, 0x22: 0x17, 0x26: 0x24, 0x28: 0x25, 0x25: 0x26, 0x2E: 0x32, 0x2D: 0x31,  // H–N
        0x1F: 0x18, 0x23: 0x19, 0x0C: 0x10, 0x0F: 0x13, 0x01: 0x1F, 0x11: 0x14, 0x20: 0x16,  // O–U
        0x09: 0x2F, 0x0D: 0x11, 0x07: 0x2D, 0x10: 0x15, 0x06: 0x2C  // V–Z
    ]

    private static let digitsAndPunctuation: [UInt16: UInt8] = [
        0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x17: 0x06,  // 1–5
        0x16: 0x07, 0x1A: 0x08, 0x1C: 0x09, 0x19: 0x0A, 0x1D: 0x0B,  // 6–0
        0x1B: 0x0C,  // minus
        0x18: 0x0D,  // equals
        0x21: 0x1A,  // left bracket
        0x1E: 0x1B,  // right bracket
        0x2A: 0x2B,  // backslash
        0x29: 0x27,  // semicolon
        0x27: 0x28,  // quote
        0x2B: 0x33,  // comma
        0x2F: 0x34,  // period
        0x2C: 0x35,  // slash
        0x24: 0x1C,  // Return
        0x30: 0x0F,  // Tab
        0x31: 0x39,  // Space
        0x33: 0x0E,  // Delete, which is Backspace on a PC
        0x35: 0x01  // Escape
    ]

    private static let functionKeys: [UInt16: UInt8] = [
        0x7A: 0x3B, 0x78: 0x3C, 0x63: 0x3D, 0x76: 0x3E, 0x60: 0x3F, 0x61: 0x40,  // F1–F6
        0x62: 0x41, 0x64: 0x42, 0x65: 0x43, 0x6D: 0x44, 0x67: 0x57, 0x6F: 0x58,  // F7–F12
        // F14 sits where a PC keyboard has Scroll Lock.
        0x6B: 0x46,
        0x71: 0x66, 0x6A: 0x67, 0x40: 0x68, 0x4F: 0x69, 0x50: 0x6A, 0x5A: 0x6B  // F15–F20
    ]

    /// The keypad always types digits: a Mac has no Num Lock, so Vistara
    /// tells the server that Num Lock is on. Clear, which sits where a PC has
    /// Num Lock, is therefore not sent.
    private static let keypad: [UInt16: UInt8] = [
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B,  // 0–4
        0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47, 0x5B: 0x48, 0x5C: 0x49,  // 5–9
        0x41: 0x53,  // decimal
        0x43: 0x37,  // multiply
        0x45: 0x4E,  // plus
        0x4E: 0x4A  // minus
    ]

    private static let japanese: [UInt16: UInt8] = [
        0x5D: 0x7D,  // Yen
        0x5E: 0x73,  // underscore
        0x5F: 0x7E,  // keypad comma
        0x66: 0x7B,  // Eisu, as "no conversion"
        0x68: 0x79  // Kana, as "conversion"
    ]

    private static let extended: [UInt16: UInt8] = [
        0x7B: 0x4B, 0x7C: 0x4D, 0x7D: 0x50, 0x7E: 0x48,  // arrows: left, right, down, up
        0x73: 0x47,  // Home
        0x77: 0x4F,  // End
        0x74: 0x49,  // Page Up
        0x79: 0x51,  // Page Down
        0x75: 0x53,  // Forward Delete
        0x72: 0x52,  // Help, which sits where a PC has Insert
        0x4C: 0x1C,  // keypad Enter
        0x4B: 0x35,  // keypad divide
        0x6E: 0x5D,  // context menu
        // F13 sits where a PC keyboard has Print Screen.
        0x69: 0x37
    ]
}
