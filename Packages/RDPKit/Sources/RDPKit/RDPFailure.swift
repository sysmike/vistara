import Foundation

/// Why a connection could not be made, or why it ended, in terms a person
/// can act on, together with FreeRDP's own account of it for bug reports.
public struct RDPFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, CaseIterable {
        // Reaching the computer
        case hostNotFound
        /// No route: the network or a VPN is missing.
        case unreachable
        /// Nothing answered in time.
        case notResponding
        /// Something answered and refused.
        case refused
        /// The computer is still starting.
        case starting
        /// Could not connect, for no reason more specific than that.
        case cannotConnect

        // Signing in
        case wrongCredentials
        case passwordExpired
        /// Disabled, locked, expired, or not allowed to sign in remotely.
        case accountRestricted
        /// The computer and Vistara agree on no security protocol.
        case securityMismatch

        // While connected
        case endedByServer
        case replacedByAnotherConnection
        case idleTimeout
        case signedOut
        case networkLost

        // Going through a gateway
        /// The gateway cannot be found, reached, or does not answer.
        case gatewayUnreachable
        /// The gateway did not accept the user name or password.
        case gatewaySignInRefused
        /// The gateway does not allow a connection to this computer: its
        /// resource authorization policy.
        case gatewayRefusedComputer

        // Anything else
        case licensing
        case protocolError
    }

    public var kind: Kind
    /// FreeRDP's error code: class in the upper 16 bits, error below.
    public var code: UInt32
    /// FreeRDP's name for the error, for example "ERRCONNECT_CONNECT_FAILED".
    public var name: String
    /// FreeRDP's English description of the error.
    public var description: String
    /// The operating system's error from a failed TCP connection, if any.
    public var osError: Int32?

    public init(
        kind: Kind, code: UInt32 = 0, name: String = "", description: String = "", osError: Int32? = nil
    ) {
        self.kind = kind
        self.code = code
        self.name = name
        self.description = description
        self.osError = osError
    }

    /// Classifies a FreeRDP error. `whileConnected` says whether the session
    /// had been established, because the same transport error means "could
    /// not connect" before and "the network went away" after. `atGateway`
    /// says that the connection never got past its gateway, so that what
    /// went wrong is the gateway's: its address, its sign-in, or its policy.
    public static func kind(code: UInt32, osError: Int32?, whileConnected: Bool, atGateway: Bool = false) -> Kind {
        if let kind = gatewayKind(code) { return kind }
        let kind = connectionKind(code: code, osError: osError, whileConnected: whileConnected)
        guard atGateway, !whileConnected else { return kind }
        switch kind {
        case .hostNotFound, .unreachable, .notResponding, .refused, .cannotConnect: return .gatewayUnreachable
        case .wrongCredentials, .accountRestricted: return .gatewaySignInRefused
        default: return kind
        }
    }

    private static func connectionKind(code: UInt32, osError: Int32?, whileConnected: Bool) -> Kind {
        let errorClass = code >> 16
        let error = code & 0xFFFF
        switch errorClass {
        case Self.serverClass:
            return serverKind(error) ?? (whileConnected ? .networkLost : .cannotConnect)
        case Self.connectClass:
            if let kind = connectKind(error, osError: osError) { return kind }
            return whileConnected ? .networkLost : .cannotConnect
        default:
            return whileConnected ? .networkLost : .cannotConnect
        }
    }

    static let serverClass: UInt32 = 1
    static let connectClass: UInt32 = 2

    /// Errors the server reported, ERRINFO_* in freerdp/error.h.
    private static func serverKind(_ error: UInt32) -> Kind? {
        switch error {
        case 0x01, 0x0B: .endedByServer  // RPC_INITIATED_DISCONNECT, _BY_USER
        case 0x02, 0x0C: .signedOut  // RPC_INITIATED_LOGOFF, LOGOFF_BY_USER
        case 0x03, 0x04: .idleTimeout  // IDLE_TIMEOUT, LOGON_TIMEOUT
        case 0x05: .replacedByAnotherConnection  // DISCONNECTED_BY_OTHER_CONNECTION
        case 0x07, 0x09: .accountRestricted  // SERVER_DENIED_CONNECTION, _INSUFFICIENT_PRIVILEGES
        case 0x0A: .wrongCredentials  // SERVER_FRESH_CREDENTIALS_REQUIRED
        case 0x100...0x10A: .licensing  // LICENSE_*
        case 0x400...0x412: .starting  // CB_* (connection broker)
        case 0x10C9...0x1FFF: .protocolError
        default: nil
        }
    }

    /// Connection errors, ERRCONNECT_* in freerdp/error.h.
    private static func connectKind(_ error: UInt32, osError: Int32?) -> Kind? {
        switch error {
        case 0x04, 0x05: return .hostNotFound  // DNS_ERROR, DNS_NAME_NOT_FOUND
        case 0x06, 0x0D:  // CONNECT_FAILED, CONNECT_TRANSPORT_FAILED
            return osError.flatMap(networkKind)
        case 0x09, 0x14, 0x15, 0x1B: return .wrongCredentials  // AUTHENTICATION_FAILED, LOGON_FAILURE,
        // WRONG_PASSWORD, NO_OR_MISSING_CREDENTIALS
        case 0x0E, 0x0F, 0x13: return .passwordExpired  // PASSWORD_EXPIRED, _CERTAINLY_, _MUST_CHANGE
        case 0x0A, 0x10, 0x12, 0x16, 0x17, 0x18, 0x19, 0x1A:
            // INSUFFICIENT_PRIVILEGES, CLIENT_REVOKED, ACCOUNT_DISABLED, ACCESS_DENIED,
            // ACCOUNT_RESTRICTION, ACCOUNT_LOCKED_OUT, ACCOUNT_EXPIRED, LOGON_TYPE_NOT_GRANTED
            return .accountRestricted
        case 0x0C, 0x1E, 0x1F: return .securityMismatch  // SECURITY_NEGO_CONNECT_FAILED,
        // HYBRID_REQUIRED_BY_SERVER, NTLM_BLOCKED
        case 0x1C: return .notResponding  // ACTIVATION_TIMEOUT
        case 0x1D: return .starting  // TARGET_BOOTING
        case 0x07: return .protocolError  // MCS_CONNECT_INITIAL_ERROR
        default: return nil
        }
    }

    /// What the gateway answered, E_PROXY_* from [MS-TSGU] 2.2.6, which
    /// FreeRDP passes on as the error code itself.
    private static func gatewayKind(_ code: UInt32) -> Kind? {
        switch code {
        case 0x8007_59DA, 0x0000_59FC: .gatewayRefusedComputer  // RAP_ACCESSDENIED, REAUTH_RAP_FAILED
        case 0x8007_59F8, 0x0000_59FA: .gatewaySignInRefused  // COOKIE_AUTHENTICATION_ACCESS_DENIED,
        // REAUTH_AUTHN_FAILED
        default: nil
        }
    }

    /// What a failed TCP connection's errno says.
    private static func networkKind(_ osError: Int32) -> Kind? {
        switch osError {
        case ECONNREFUSED: .refused
        case ETIMEDOUT: .notResponding
        case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN: .unreachable
        default: nil
        }
    }

    /// The technical detail for a bug report: FreeRDP's name, code, and
    /// description, and the system error. Never names an account.
    public var technicalDetail: String {
        var lines: [String] = []
        if !name.isEmpty { lines.append("\(name) (0x\(String(format: "%08X", code)))") }
        if !description.isEmpty { lines.append(description) }
        if let osError, osError != 0 {
            lines.append("System error \(osError): \(String(cString: strerror(osError)))")
        }
        return lines.joined(separator: "\n")
    }
}
