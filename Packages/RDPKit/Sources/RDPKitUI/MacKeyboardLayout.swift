import Carbon.HIToolbox
import RDPKit

/// The Windows keyboard layout that matches the Mac's input source, so that a
/// new remote session types what the key caps say. Keys are still sent by
/// position; this only tells the server which layout to start with.
public enum MacKeyboardLayout {
    /// Windows keyboard layout identifiers (KLIDs) for Mac keyboard layouts,
    /// by the part of the input source ID after "com.apple.keylayout.".
    static let layouts: [String: UInt32] = [
        "US": 0x0000_0409, "ABC": 0x0000_0409, "Australian": 0x0000_0409, "Colemak": 0x0000_0409,
        "USInternational-PC": 0x0002_0409, "USExtended": 0x0002_0409, "ABC-Extended": 0x0002_0409,
        "Dvorak": 0x0001_0409, "DVORAK-QWERTYCMD": 0x0001_0409,
        "British": 0x0000_0809, "British-PC": 0x0000_0809, "Irish": 0x0000_1809,
        "Canadian-CSA": 0x0001_1009,
        "German": 0x0000_0407, "Austrian": 0x0000_0407, "SwissGerman": 0x0000_0807, "SwissFrench": 0x0000_100C,
        "French": 0x0000_040C, "French-PC": 0x0000_040C, "French-numerical": 0x0000_040C, "Belgian": 0x0000_080C,
        "Spanish": 0x0000_040A, "Spanish-ISO": 0x0000_040A, "LatinAmerican": 0x0000_080A,
        "Italian": 0x0000_0410, "Italian-Pro": 0x0000_0410,
        "Portuguese": 0x0000_0816, "Brazilian": 0x0000_0416, "Brazilian-ABNT2": 0x0000_0416,
        "Brazilian-Pro": 0x0000_0416,
        "Dutch": 0x0000_0413, "Danish": 0x0000_0406, "Norwegian": 0x0000_0414, "NorwegianExtended": 0x0000_0414,
        "Swedish": 0x0000_041D, "Swedish-Pro": 0x0000_041D, "Finnish": 0x0000_040B, "FinnishExtended": 0x0000_040B,
        "Icelandic": 0x0000_040F,
        "PolishPro": 0x0000_0415, "Polish": 0x0001_0415,
        "Czech": 0x0000_0405, "Czech-QWERTY": 0x0001_0405, "Slovak": 0x0000_041B, "Slovak-QWERTY": 0x0001_041B,
        "Hungarian": 0x0000_040E, "Slovenian": 0x0000_0424, "Croatian": 0x0000_041A, "Romanian": 0x0001_0418,
        "Estonian": 0x0000_0425, "Latvian": 0x0000_0426, "Lithuanian": 0x0001_0427,
        "Russian": 0x0000_0419, "RussianWin": 0x0000_0419, "Russian-Phonetic": 0x0001_0419,
        "Ukrainian": 0x0000_0422, "Ukrainian-PC": 0x0000_0422, "Belarusian": 0x0000_0423,
        "Bulgarian": 0x0000_0402,
        "Greek": 0x0000_0408, "Turkish-QWERTY-PC": 0x0000_041F, "Turkish-QWERTY": 0x0000_041F,
        "Turkish": 0x0001_041F,
        "Hebrew": 0x0000_040D, "Arabic": 0x0000_0401, "Thai": 0x0000_041E
    ]

    /// Input methods, which type through a layout of their own, by prefix.
    static let inputMethods: [(prefix: String, layout: UInt32)] = [
        ("com.apple.inputmethod.Kotoeri", 0x0000_0411),
        ("com.apple.inputmethod.Korean", 0x0000_0412),
        ("com.apple.inputmethod.SCIM", 0x0000_0804),
        ("com.apple.inputmethod.TCIM", 0x0000_0404)
    ]

    static let japanese: UInt32 = 0x0000_0411

    /// The Windows layout for a Mac input source ID, or nil when there is no
    /// clear match; the server then decides, as it does without one.
    public static func windowsLayout(forInputSource id: String) -> UInt32? {
        let prefix = "com.apple.keylayout."
        if id.hasPrefix(prefix) { return layouts[String(id.dropFirst(prefix.count))] }
        return inputMethods.first { id.hasPrefix($0.prefix) }?.layout
    }

    /// The keyboard to announce for a layout on a keyboard of the given
    /// shape: a Japanese keyboard is a different kind of keyboard to Windows.
    public static func keyboard(layout: UInt32, kind: MacKeyboardKind) -> RDPKeyboard {
        guard layout == japanese, kind == .jis else { return RDPKeyboard(layout: layout) }
        // [MS-RDPBCGR] 2.2.1.3.2: Japanese keyboard, 106 or 109 keys, 12 function keys.
        return RDPKeyboard(layout: layout, type: 7, subtype: 2, functionKeys: 12)
    }

    /// The keyboard for the current input source, or nil when it has no
    /// clear Windows match. Reads the input method first, then its layout.
    @MainActor public static var current: RDPKeyboard? {
        let sources = [TISCopyCurrentKeyboardInputSource(), TISCopyCurrentKeyboardLayoutInputSource()]
        for case let source? in sources.map({ $0?.takeRetainedValue() }) {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            if let layout = windowsLayout(forInputSource: id) {
                return keyboard(layout: layout, kind: MacKeyboard.current)
            }
        }
        return nil
    }
}
