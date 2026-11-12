/// A key as RDP identifies it: a position on the keyboard, not a character.
/// The remote computer's own keyboard layout decides what the key types.
public struct RDPScancode: Sendable, Hashable {
    public var code: UInt8
    /// The extended (E0) variant, as for the arrow keys and the right-hand
    /// Control and Alt keys.
    public var isExtended: Bool

    public init(_ code: UInt8, extended: Bool = false) {
        self.code = code
        self.isExtended = extended
    }

    public static let leftControl = RDPScancode(0x1D)
    public static let rightControl = RDPScancode(0x1D, extended: true)
    public static let leftShift = RDPScancode(0x2A)
    public static let rightShift = RDPScancode(0x36)
    public static let leftAlt = RDPScancode(0x38)
    public static let rightAlt = RDPScancode(0x38, extended: true)
    public static let leftWindows = RDPScancode(0x5B, extended: true)
    public static let capsLock = RDPScancode(0x3A)
    public static let delete = RDPScancode(0x53, extended: true)
}

/// The lock keys that are on.
public struct RDPLockState: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let capsLock = RDPLockState(rawValue: 1 << 0)
    public static let numLock = RDPLockState(rawValue: 1 << 1)
    public static let scrollLock = RDPLockState(rawValue: 1 << 2)
}

/// Something the user did that the remote computer should know about.
/// Input is never logged.
public enum RDPInputEvent: Sendable, Hashable {
    case key(RDPScancode, isDown: Bool)
    /// States the lock keys. The server also treats every key as released.
    case lockState(RDPLockState)

    /// A press followed by a release.
    public static func tap(_ scancode: RDPScancode) -> [RDPInputEvent] {
        [.key(scancode, isDown: true), .key(scancode, isDown: false)]
    }

    /// Control, Alt, and Delete pressed together, then released.
    public static let controlAltDelete: [RDPInputEvent] = [
        .key(.leftControl, isDown: true),
        .key(.leftAlt, isDown: true),
        .key(.delete, isDown: true),
        .key(.delete, isDown: false),
        .key(.leftAlt, isDown: false),
        .key(.leftControl, isDown: false)
    ]
}
