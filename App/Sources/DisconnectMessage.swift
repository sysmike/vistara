import RDPKit

/// What a session window says after the session ended: what happened, what
/// to do, and a button that does it. The wording follows docs/DESIGN.md.
struct DisconnectMessage: Equatable {
    enum Action: Equatable {
        /// Connect again, under the given button title.
        case connect(String)
        /// Connect again and ask for credentials, even when some are saved.
        case useAnotherAccount
        /// Connect again and ask for the gateway's own account, even when one
        /// is saved.
        case useAnotherGatewayAccount
        /// Open the saved connection in the editor.
        case editConnection

        var title: String {
            switch self {
            case .connect(let title): title
            case .useAnotherAccount, .useAnotherGatewayAccount: "Use Another Account"
            case .editConnection: "Edit Connection"
            }
        }
    }

    var title: String
    var explanation: String?
    var action: Action?
    /// A second, less likely button beside `action`.
    var secondaryAction: Action?
    /// Technical detail for a bug report, behind a disclosure. Never names an
    /// account and never holds a password.
    var detail: String?

    /// Where a session went: the connection's name, the address connected
    /// to, and the gateway it went through, if any.
    struct Destination: Equatable {
        var name: String
        var host: String
        /// The gateway's address.
        var gateway: String?
        /// The gateway signs in with an account of its own, not the computer's.
        var gatewayHasOwnAccount = false

        /// "The gateway “gw.example.com”", or "The gateway" without its address.
        var gatewayPhrase: String {
            gateway.map { "The gateway “\($0)”" } ?? "The gateway"
        }
    }

    /// `name` is the connection's name, `host` the address connected to.
    /// `canEditConnection` offers Edit Connection where a wrong address or
    /// port is a likely cause. `gaveUpReconnecting` says Vistara already tried
    /// to bring a lost session back.
    init(
        reason: RDPDisconnectReason, name: String, host: String, gateway: String? = nil,
        gatewayHasOwnAccount: Bool = false, canEditConnection: Bool = false, refusedByPolicy: Bool = false,
        gaveUpReconnecting: Bool = false
    ) {
        let destination = Destination(
            name: name, host: host, gateway: gateway, gatewayHasOwnAccount: gatewayHasOwnAccount
        )
        if reason == .certificateRejected, refusedByPolicy {
            self.init(
                "“\(name)” presented a certificate this connection doesn’t trust",
                "This connection accepts only certificates you or your Mac already trust. "
                    + "To review this one, set Certificate to Ask on First Use in Edit Connection.",
                canEditConnection ? .editConnection : nil
            )
            return
        }
        switch reason {
        // Disconnecting a running session closes its window, so a window only
        // shows this after Cancel while connecting.
        case .userRequested, .credentialsCancelled:
            self.init("Connection cancelled", nil, .connect("Try Again"))
        case .certificateRejected:
            self.init(
                "Connection cancelled", "You chose not to trust this computer’s certificate.", .connect("Try Again")
            )
        case .authenticationFailed:
            // Normally the credentials sheet returns instead of this.
            self.init("The user name or password is incorrect", nil, .useAnotherAccount)
        case .connectionFailed(let failure), .connectionLost(let failure):
            if let gatewayMessage = Self.gatewayMessage(failure.kind, destination) {
                self = gatewayMessage
            } else {
                self.init(failure.kind, name: name, host: host)
            }
            let addressMayBeWrong: [RDPFailure.Kind] = [
                .hostNotFound, .refused, .cannotConnect, .gatewayUnreachable, .gatewayRefusedComputer
            ]
            if canEditConnection, addressMayBeWrong.contains(failure.kind) {
                secondaryAction = .editConnection
            }
            if gaveUpReconnecting, failure.kind == .networkLost {
                explanation = "Vistara couldn’t reconnect for a minute. Check your network connection, "
                    + "then reconnect. Your session keeps running on the computer."
            }
            let detail = failure.technicalDetail
            self.detail = detail.isEmpty ? nil : detail
        }
    }

    private init(_ title: String, _ explanation: String?, _ action: Action?) {
        self.title = title
        self.explanation = explanation
        self.action = action
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private init(_ kind: RDPFailure.Kind, name: String, host: String) {
        let tryAgain = Action.connect("Try Again")
        let reconnect = Action.connect("Reconnect")
        switch kind {
        case .hostNotFound:
            self.init(
                "Can’t find “\(host)”", "Check the computer’s name, and your network and VPN connection.", tryAgain
            )
        case .unreachable:
            self.init(
                "Can’t reach “\(name)”",
                "Your Mac has no route to that computer. Check your network and VPN connection.",
                tryAgain
            )
        case .notResponding:
            self.init(
                "“\(name)” isn’t responding", "The computer may be off, asleep, or blocked by a firewall.", tryAgain
            )
        case .refused:
            self.init(
                "“\(name)” refused the connection",
                "Remote Desktop may be turned off on that computer, or it uses a different port.",
                tryAgain
            )
        case .starting:
            self.init("“\(name)” is still starting up", "Wait a moment, then try again.", tryAgain)
        // The gateway's own words, from gatewayMessage(_:_:), name it.
        case .cannotConnect, .gatewayUnreachable, .gatewaySignInRefused, .gatewayRefusedComputer:
            self.init(
                "Can’t connect to “\(name)”",
                "Check the computer’s name and your network connection, and that Remote Desktop is enabled there.",
                tryAgain
            )
        case .wrongCredentials:
            self.init("The user name or password is incorrect", nil, .useAnotherAccount)
        case .passwordExpired:
            self.init(
                "The password for this account has expired",
                "Change it on a computer that can sign in, or ask your administrator, then connect again.",
                .useAnotherAccount
            )
        case .accountRestricted:
            self.init(
                "This account can’t sign in remotely",
                "Ask the computer’s administrator to allow Remote Desktop for this account.",
                .useAnotherAccount
            )
        case .securityMismatch:
            self.init(
                "“\(name)” requires a kind of sign-in Vistara doesn’t support",
                "Ask the computer’s administrator which sign-in methods Remote Desktop accepts there.",
                tryAgain
            )
        case .endedByServer:
            self.init(
                "“\(name)” ended the session",
                "An administrator or a program on that computer disconnected you.",
                reconnect
            )
        case .replacedByAnotherConnection:
            self.init(
                "Another connection took over this session",
                "The same account connected to “\(name)” from somewhere else.",
                reconnect
            )
        case .idleTimeout:
            self.init(
                "“\(name)” ended the session after a period of inactivity",
                "Reconnect to continue where you left off.",
                reconnect
            )
        case .signedOut:
            self.init("You signed out of “\(name)”", "Connect again to start a new session.", .connect("Connect"))
        case .networkLost:
            self.init(
                "The connection to “\(name)” was lost",
                "Check your network connection, then reconnect. Your session keeps running on the computer.",
                reconnect
            )
        case .licensing:
            self.init(
                "“\(name)” has no Remote Desktop license for this connection",
                "Ask the computer’s administrator to check its Remote Desktop licensing.",
                tryAgain
            )
        case .protocolError:
            self.init(
                "“\(name)” closed the connection unexpectedly",
                "Try again. If it keeps happening, copy the details below into a bug report.",
                tryAgain
            )
        }
    }
}

extension DisconnectMessage {
    /// When the gateway is what failed, the window says so and offers what
    /// helps (docs/DESIGN.md, RD Gateway and Errors).
    fileprivate static func gatewayMessage(_ kind: RDPFailure.Kind, _ destination: Destination) -> Self? {
        let gateway = destination.gatewayPhrase
        switch kind {
        case .gatewayUnreachable:
            let lowercased = gateway.prefix(1).lowercased() + gateway.dropFirst()
            return DisconnectMessage(
                "Can’t reach \(lowercased)",
                "Check the gateway’s address, and your network and VPN connection.",
                .connect("Try Again")
            )
        case .gatewaySignInRefused:
            return DisconnectMessage(
                "\(gateway) didn’t accept the user name or password",
                destination.gatewayHasOwnAccount
                    ? "Sign in with the account the gateway knows you by."
                    : "This connection signs in to the gateway with the computer’s account. Try another one.",
                destination.gatewayHasOwnAccount ? .useAnotherGatewayAccount : .useAnotherAccount
            )
        case .gatewayRefusedComputer:
            return DisconnectMessage(
                "\(gateway) doesn’t allow a connection to “\(destination.name)”",
                "Its policy doesn’t include this computer. Ask whoever runs the gateway to allow it.",
                .connect("Try Again")
            )
        default:
            return nil
        }
    }
}

extension SessionModel {
    /// What the window says about a session that ended.
    func disconnectMessage(for reason: RDPDisconnectReason) -> DisconnectMessage {
        DisconnectMessage(
            reason: reason, name: target.name, host: target.host,
            gateway: target.gateway?.host, gatewayHasOwnAccount: target.gateway?.signIn == .anotherAccount,
            canEditConnection: onEditConnection != nil,
            refusedByPolicy: refusedCertificateByPolicy,
            gaveUpReconnecting: didGiveUpReconnecting
        )
    }
}
