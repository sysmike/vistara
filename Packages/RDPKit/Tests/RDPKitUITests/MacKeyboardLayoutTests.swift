import RDPKit
import Testing

@testable import RDPKitUI

@Suite
struct MacKeyboardLayoutTests {
    @Test(arguments: [
        ("com.apple.keylayout.US", 0x0000_0409),
        ("com.apple.keylayout.ABC", 0x0000_0409),
        ("com.apple.keylayout.German", 0x0000_0407),
        ("com.apple.keylayout.SwissGerman", 0x0000_0807),
        ("com.apple.keylayout.British", 0x0000_0809),
        ("com.apple.keylayout.French", 0x0000_040C),
        ("com.apple.keylayout.Spanish-ISO", 0x0000_040A),
        ("com.apple.keylayout.Italian-Pro", 0x0000_0410),
        ("com.apple.keylayout.Swedish-Pro", 0x0000_041D),
        ("com.apple.keylayout.Russian", 0x0000_0419),
        ("com.apple.keylayout.Dvorak", 0x0001_0409),
        ("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", 0x0000_0411),
        ("com.apple.inputmethod.Korean.2SetKorean", 0x0000_0412)
    ] as [(String, UInt32)])
    func commonLayoutsMapToTheirWindowsLayout(source: String, layout: UInt32) {
        #expect(MacKeyboardLayout.windowsLayout(forInputSource: source) == layout)
    }

    @Test
    func anUnknownSourceLeavesTheLayoutToTheServer() {
        #expect(MacKeyboardLayout.windowsLayout(forInputSource: "com.apple.keylayout.Klingon") == nil)
        #expect(MacKeyboardLayout.windowsLayout(forInputSource: "org.example.custom") == nil)
        #expect(MacKeyboardLayout.windowsLayout(forInputSource: "") == nil)
    }

    @Test
    func aJapaneseKeyboardIsAnnouncedAsOne() {
        let jis = MacKeyboardLayout.keyboard(layout: 0x0411, kind: .jis)
        #expect(jis == RDPKeyboard(layout: 0x0411, type: 7, subtype: 2, functionKeys: 12))
        // Japanese typed on another keyboard keeps the standard keyboard type.
        #expect(MacKeyboardLayout.keyboard(layout: 0x0411, kind: .ansi) == RDPKeyboard(layout: 0x0411))
        #expect(MacKeyboardLayout.keyboard(layout: 0x0407, kind: .iso) == RDPKeyboard(layout: 0x0407))
    }

    @Test
    func everyLayoutIsAPlausibleWindowsIdentifier() {
        for (name, layout) in MacKeyboardLayout.layouts {
            // A language identifier in the low word, a variant in the high word.
            #expect(layout & 0xFFFF != 0, "\(name)")
            #expect(layout >> 16 < 0x10, "\(name)")
        }
    }
}
