/// What a session connects to and how. Holds no password: the session asks
/// for credentials when it needs them.
public struct RDPSessionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var domain: String?
    public var desktopWidth: UInt32
    public var desktopHeight: UInt32
    /// Desktop scale in percent: 100 for standard displays, 200 for Retina.
    public var scalePercent: UInt32
    /// When false, a server without Network Level Authentication is accepted
    /// over TLS. Legacy RDP security is never used.
    public var requiresNLA: Bool

    public init(
        host: String,
        port: UInt16 = 3389,
        username: String = "",
        domain: String? = nil,
        desktopWidth: UInt32 = 1280,
        desktopHeight: UInt32 = 800,
        scalePercent: UInt32 = 100,
        requiresNLA: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.scalePercent = scalePercent
        self.requiresNLA = requiresNLA
    }
}

/// Credentials for one connection attempt. Keep them only as long as needed;
/// RDPKit erases its own working copy of the password after connecting.
public struct RDPCredentials: Sendable {
    public var username: String
    public var domain: String?
    public var password: String

    public init(username: String, domain: String? = nil, password: String) {
        self.username = username
        self.domain = domain
        self.password = password
    }
}

/// Printing or dumping credentials never shows them, so a password cannot
/// reach a log or a crash report that way.
extension RDPCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RDPCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A server certificate that could not be verified automatically and needs a
/// decision.
public struct RDPCertificate: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var commonName: String
    public var subject: String
    public var issuer: String
    /// SHA-256 as colon-separated hex pairs.
    public var fingerprint: String
    /// Set when a different certificate was recorded for this host before.
    public var previousFingerprint: String?

    public init(
        host: String,
        port: UInt16,
        commonName: String,
        subject: String,
        issuer: String,
        fingerprint: String,
        previousFingerprint: String? = nil
    ) {
        self.host = host
        self.port = port
        self.commonName = commonName
        self.subject = subject
        self.issuer = issuer
        self.fingerprint = fingerprint
        self.previousFingerprint = previousFingerprint
    }
}

public enum RDPDisconnectReason: Sendable, Equatable {
    /// `RDPSession.disconnect()` was called.
    case userRequested
    /// The credentials question was answered with nil.
    case credentialsCancelled
    case certificateRejected
    case authenticationFailed
    /// The connection could not be established. `code` is FreeRDP's error name.
    case connectionFailed(code: String)
    /// An established connection ended. `code` is FreeRDP's error name.
    case connectionLost(code: String)
}

public enum RDPSessionState: Sendable, Equatable {
    case connecting
    case awaitingCredentials
    case awaitingCertificateDecision(RDPCertificate)
    case connected(width: Int, height: Int)
    /// Final. The state stream ends after this.
    case disconnected(RDPDisconnectReason)
}

/// The questions a session asks while connecting. Both are answered
/// asynchronously, typically by showing a sheet.
///
/// The closures must return promptly when their task is cancelled, which
/// happens when the session is disconnected while a question is open.
public struct RDPSessionDelegate: Sendable {
    /// Returns the credentials to use, or nil to cancel the connection.
    public var credentials: @Sendable (RDPSessionConfiguration) async -> RDPCredentials?
    /// Returns true to continue with this certificate for this session.
    public var certificateDecision: @Sendable (RDPCertificate) async -> Bool

    public init(
        credentials: @escaping @Sendable (RDPSessionConfiguration) async -> RDPCredentials?,
        certificateDecision: @escaping @Sendable (RDPCertificate) async -> Bool
    ) {
        self.credentials = credentials
        self.certificateDecision = certificateDecision
    }
}
