import Foundation

/// A program to open in place of the remote desktop (RemoteApp), as the
/// remote computer publishes it.
public struct RDPProgram: Sendable, Hashable {
    /// `||ALIAS` for a published program, or a path.
    public var path: String
    /// Passed to the program; empty for none.
    public var arguments: String

    public init(path: String, arguments: String = "") {
        self.path = path
        self.arguments = arguments
    }
}

/// A rectangle in desktop pixels, origin at the top left.
public struct RDPRect: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A picture of 32-bit BGRA pixels with straight alpha, top row first.
public struct RDPImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// `width * height * 4` bytes.
    public var pixels: Data

    public init(width: Int, height: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// One window of a remote program, as the remote computer last described it.
public struct RDPRemoteWindow: Sendable, Equatable, Identifiable {
    public enum ShowState: Sendable, Equatable {
        case hidden
        case minimized
        case maximized
        case shown
    }

    public var id: UInt32
    /// The window it belongs to, such as a menu's or a dialog's.
    public var ownerID: UInt32?
    /// Windows' window styles (WS_*) and extended styles (WS_EX_*).
    public var style: UInt32
    public var extendedStyle: UInt32
    public var showState: ShowState
    /// Never logged.
    public var title: String
    /// The whole window, its own title bar and edges included.
    public var frame: RDPRect
    /// The parts of the desktop it covers, for windows that are not
    /// rectangles; the whole frame when the remote computer said nothing.
    public var visibleRegion: [RDPRect]
    /// Its largest icon so far.
    public var icon: RDPImage?
    /// Gone: this is the last word about it.
    public var isDeleted: Bool

    /// WS_POPUP: a menu, a list that drops down, or a tooltip.
    public var isPopup: Bool { style & 0x8000_0000 != 0 }
    /// WS_CAPTION: it has a title bar of its own.
    public var hasTitleBar: Bool { style & 0x00C0_0000 == 0x00C0_0000 }

    public init(
        id: UInt32, ownerID: UInt32? = nil, style: UInt32 = 0, extendedStyle: UInt32 = 0,
        showState: ShowState = .shown, title: String = "", frame: RDPRect, visibleRegion: [RDPRect] = [],
        icon: RDPImage? = nil, isDeleted: Bool = false
    ) {
        self.id = id
        self.ownerID = ownerID
        self.style = style
        self.extendedStyle = extendedStyle
        self.showState = showState
        self.title = title
        self.frame = frame
        self.visibleRegion = visibleRegion
        self.icon = icon
        self.isDeleted = isDeleted
    }
}

/// Why a program did not start ([MS-RDPERP] 2.2.2.8.1).
public enum RDPProgramFailure: Sendable, Equatable {
    /// The remote computer does not publish it, or not to this user.
    case notPublished
    /// Published, but its file is not there.
    case notFound
    /// The remote session is locked.
    case sessionLocked
    /// Anything else, with the remote computer's code.
    case failed(code: UInt32)

    init?(code: UInt32) {
        switch code {
        case 0: return nil
        case 3: self = .notPublished
        case 5: self = .notFound
        case 7: self = .sessionLocked
        default: self = .failed(code: code)
        }
    }
}

/// How large a window may be, as the remote computer says.
public struct RDPWindowSizeLimits: Sendable, Equatable {
    /// Where and how large it is when maximized.
    public var maximized: RDPRect
    public var minimumWidth: Int
    public var minimumHeight: Int
    public var maximumWidth: Int
    public var maximumHeight: Int
}

/// What a RemoteApp session reports besides its windows.
public enum RDPRemoteAppEvent: Sendable, Equatable {
    /// The program started; its windows follow.
    case programStarted
    case programFailed(RDPProgramFailure)
    /// The remote computer moves or resizes a window for the user, as when
    /// its title bar is dragged: the Mac follows the pointer until it ends.
    case moveSizeBegan(windowID: UInt32, isMove: Bool, x: Int, y: Int)
    case moveSizeEnded(windowID: UInt32, x: Int, y: Int)
    case sizeLimits(windowID: UInt32, RDPWindowSizeLimits)
    /// The programs' last window has been gone for
    /// `RDPSession.lastWindowGrace`. Told once, until another window appears.
    case lastWindowClosed
}

/// What a window's buttons and menu do.
public enum RDPWindowCommand: UInt16, Sendable, Hashable {
    case minimize = 0xF020
    case maximize = 0xF030
    case close = 0xF060
    case restore = 0xF120
}

/// What the Mac tells the remote computer about programs and their windows.
public enum RDPRemoteAppOrder: Sendable, Hashable {
    /// Starts another program in the session.
    case start(RDPProgram)
    /// A window became, or stopped being, the one in front.
    case activate(windowID: UInt32, isActive: Bool)
    /// The Mac moved or resized a window: its new frame.
    case move(windowID: UInt32, frame: RDPRect)
    case command(RDPWindowCommand, windowID: UInt32)
    /// The part of the desktop a maximized window fills.
    case workArea(RDPRect)

    func isSuperseded(by later: RDPRemoteAppOrder) -> Bool {
        switch (self, later) {
        case (.move(let id, _), .move(let laterID, _)): id == laterID
        case (.workArea, .workArea): true
        default: false
        }
    }
}
