import Foundation

/// A Remote Desktop Gateway the connection goes through: the session travels
/// as HTTPS to the gateway, which passes it on to the computer
/// (docs/DESIGN.md, RD Gateway). Only the HTTP transport is spoken, over
/// WebSocket where the gateway offers it; never RPC over HTTP or UDP.
public struct RDPGateway: Sendable, Equatable {
    /// How to sign in to the gateway.
    public enum SignIn: Sendable, Equatable {
        /// With the computer's user name and password: one password for both.
        case sameAsComputer
        /// With an account of its own, asked for before the computer's.
        case ownAccount(username: String, domain: String?)
    }

    public var host: String
    public var port: UInt16
    public var signIn: SignIn

    public init(host: String, port: UInt16 = 443, signIn: SignIn = .sameAsComputer) {
        self.host = host
        self.port = port
        self.signIn = signIn
    }
}

/// What a gateway shows before it connects ([MS-TSGU] 2.2.10.14): a notice,
/// or terms that must be accepted.
public struct RDPGatewayMessage: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Terms the user must accept; declining does not connect.
        case consent
        /// A notice from whoever runs the gateway.
        case notice
    }

    public var kind: Kind
    public var text: String
    /// The gateway asks that the message be shown.
    public var mustBeShown: Bool
    /// The gateway connects only if the user accepts.
    public var requiresConsent: Bool

    public init(kind: Kind, text: String, mustBeShown: Bool, requiresConsent: Bool) {
        self.kind = kind
        self.text = text
        self.mustBeShown = mustBeShown
        self.requiresConsent = requiresConsent
    }
}
