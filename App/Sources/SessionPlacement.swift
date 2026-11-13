import AppKit

/// Where a new session opens: as a tab of the session window in front, or
/// in a window of its own (docs/DESIGN.md, Session tabs).
enum SessionPlacement: Equatable, Sendable {
    case tab
    case window

    /// Where Option sends a session instead.
    var other: SessionPlacement {
        self == .tab ? .window : .tab
    }

    /// The Connect command that opens a session here.
    var connectTitle: String {
        self == .tab ? "Connect in New Tab" : "Connect in New Window"
    }

    /// Where the system's "Prefer tabs when opening documents" setting puts a
    /// new session. `frontIsFullScreen` describes the session window in
    /// front, or is nil when there is none to join.
    static func preferred(by preference: NSWindow.UserTabbingPreference, frontIsFullScreen: Bool?) -> SessionPlacement {
        guard let frontIsFullScreen else { return .window }
        switch preference {
        case .always: return .tab
        case .inFullScreen: return frontIsFullScreen ? .tab : .window
        case .manual: return .window
        @unknown default: return .window
        }
    }
}
