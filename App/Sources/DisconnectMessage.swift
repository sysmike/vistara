import RDPKit

/// What a session window says after the session ended. The full catalogue
/// of messages arrives with issue #17.
struct DisconnectMessage: Equatable {
    var title: String
    var explanation: String?
    /// Title of the button that connects again, when that can help.
    var action: String?
    /// FreeRDP's name for the error, for bug reports.
    var detail: String?

    init(reason: RDPDisconnectReason, name: String) {
        switch reason {
        case .userRequested:
            title = "Disconnected from “\(name)”"
            explanation = "Programs on the remote computer keep running."
            action = "Reconnect"
        case .credentialsCancelled:
            title = "Connection cancelled"
            action = "Try Again"
        case .certificateRejected:
            title = "Connection cancelled"
            explanation = "You chose not to trust this computer’s certificate."
            action = "Try Again"
        case .authenticationFailed:
            title = "The user name or password is incorrect"
            explanation = "Close this window and connect again."
        case .connectionFailed(let code):
            title = "Can’t connect to “\(name)”"
            explanation = "Check the name and your network connection, and that Remote Desktop is enabled on "
                + "that computer."
            action = "Try Again"
            detail = code
        case .connectionLost(let code):
            title = "The connection to “\(name)” was lost"
            explanation = "The network may have dropped, or the computer ended the session."
            action = "Reconnect"
            detail = code
        }
    }
}
