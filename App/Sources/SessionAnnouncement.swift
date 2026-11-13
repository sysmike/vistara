import AppKit

/// What VoiceOver says when a session window changes state, for people who
/// cannot see the window change (docs/DESIGN.md, Accessibility).
enum SessionAnnouncement {
    /// Which state a phase is, ignoring its details, so that each attempt
    /// while reconnecting is not announced again.
    enum Kind: Equatable {
        case connecting, connected, reconnecting, disconnected
    }

    static func kind(of phase: SessionModel.Phase) -> Kind {
        switch phase {
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .disconnected: .disconnected
        }
    }

    /// What to say on entering `phase`, or nil. Connecting is announced by
    /// the window's own text as it appears.
    static func text(for phase: SessionModel.Phase, name: String, message: DisconnectMessage?) -> String? {
        switch phase {
        case .connecting: nil
        case .connected: "Connected to “\(name)”"
        case .reconnecting: "The connection was lost. Reconnecting to “\(name)”"
        case .disconnected: message?.title
        }
    }

    /// Sees each announcement as it is posted. For tests.
    @MainActor static var observer: ((String) -> Void)?

    @MainActor
    static func post(_ text: String) {
        observer?(text)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
