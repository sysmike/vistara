import Foundation

/// Where the remote computer's sound goes.
public enum RDPAudioMode: Sendable, Hashable {
    /// Sent to this Mac and played through its default output, which may
    /// change while connected.
    case thisMac
    /// Played on the remote computer.
    case remote
    case off
}

/// The keyboard the client announces when connecting, which a server may use
/// as the session's starting layout ([MS-RDPBCGR] 2.2.1.3.2).
public struct RDPKeyboard: Sendable, Equatable {
    /// A Windows keyboard layout identifier, such as 0x0407 for German.
    public var layout: UInt32
    /// Keyboard type, subtype, and number of function keys. Zero keeps
    /// FreeRDP's IBM enhanced (101 or 102 keys) keyboard.
    public var type: UInt32
    public var subtype: UInt32
    public var functionKeys: UInt32

    public init(layout: UInt32, type: UInt32 = 0, subtype: UInt32 = 0, functionKeys: UInt32 = 0) {
        self.layout = layout
        self.type = type
        self.subtype = subtype
        self.functionKeys = functionKeys
    }
}

/// A Mac folder shared with the remote computer, which sees it as a drive.
public struct RDPSharedFolder: Sendable, Equatable {
    /// The drive's name on the remote computer.
    public var name: String
    /// The folder's absolute path. The process must be able to open it: inside
    /// the App Sandbox, through a security-scoped bookmark.
    public var path: String
    /// The remote computer may read but not change anything in the folder.
    public var isReadOnly: Bool

    public init(name: String, path: String, isReadOnly: Bool) {
        self.name = name
        self.path = path
        self.isReadOnly = isReadOnly
    }
}

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
    public var audio: RDPAudioMode
    /// Loads the clipboard channel and shares text both ways. When false the
    /// channel is not loaded at all.
    public var sharesClipboard: Bool
    /// The only folders the remote computer sees. Empty: none, and the device
    /// redirection channel is not loaded.
    public var sharedFolders: [RDPSharedFolder]
    /// The keyboard to announce. Nil leaves the layout to the server.
    public var keyboard: RDPKeyboard?
    /// Applied by reconnection (issue #28).
    public var reconnectsAutomatically: Bool
    /// Several monitors for one desktop across them. With fewer than two, one
    /// monitor of `desktopWidth` x `desktopHeight` at `scalePercent`.
    public var monitors: [RDPMonitor] = []

    public init(
        host: String,
        port: UInt16 = 3389,
        username: String = "",
        domain: String? = nil,
        desktopWidth: UInt32 = 1280,
        desktopHeight: UInt32 = 800,
        scalePercent: UInt32 = 100,
        requiresNLA: Bool = true,
        audio: RDPAudioMode = .thisMac,
        sharesClipboard: Bool = true,
        sharedFolders: [RDPSharedFolder] = [],
        keyboard: RDPKeyboard? = nil,
        reconnectsAutomatically: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.scalePercent = scalePercent
        self.requiresNLA = requiresNLA
        self.audio = audio
        self.sharesClipboard = sharesClipboard
        self.sharedFolders = sharedFolders
        self.keyboard = keyboard
        self.reconnectsAutomatically = reconnectsAutomatically
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

/// A server certificate that the system does not trust on its own and that
/// needs a decision.
public struct RDPCertificate: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var commonName: String
    public var subject: String
    public var issuer: String
    /// SHA-256 of the certificate as colon-separated lowercase hex pairs.
    public var fingerprint: String
    public var validFrom: Date?
    public var validUntil: Date?
    /// The certificate and the rest of the chain the server sent, each in DER.
    public var chain: [Data]
    /// Set by whoever keeps a trust store, when a different certificate was
    /// trusted for this host before.
    public var previousFingerprint: String?

    public init(
        host: String,
        port: UInt16,
        commonName: String,
        subject: String,
        issuer: String,
        fingerprint: String,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        chain: [Data] = [],
        previousFingerprint: String? = nil
    ) {
        self.host = host
        self.port = port
        self.commonName = commonName
        self.subject = subject
        self.issuer = issuer
        self.fingerprint = fingerprint
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.chain = chain
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
    /// The connection could not be established.
    case connectionFailed(RDPFailure)
    /// An established connection ended.
    case connectionLost(RDPFailure)
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

extension RDPDisconnectReason {
    /// For the log: the kind of ending and FreeRDP's error name, never a
    /// host or an account.
    var logDescription: String {
        switch self {
        case .userRequested: "user requested"
        case .credentialsCancelled: "credentials cancelled"
        case .certificateRejected: "certificate rejected"
        case .authenticationFailed: "authentication failed"
        case .connectionFailed(let failure): "connection failed, \(failure.kind), \(failure.name)"
        case .connectionLost(let failure): "connection lost, \(failure.kind), \(failure.name)"
        }
    }
}
