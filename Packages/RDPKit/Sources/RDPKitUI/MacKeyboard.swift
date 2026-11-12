import Carbon.HIToolbox

enum MacKeyboard {
    /// The shape of the keyboard that was used last.
    @MainActor static var current: MacKeyboardKind {
        let layout = Int(KBGetLayoutType(Int16(LMGetKbdType())))
        if layout == kKeyboardISO { return .iso }
        if layout == kKeyboardJIS { return .jis }
        return .ansi
    }
}
