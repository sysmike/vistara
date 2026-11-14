import Foundation

extension Connection {
    public typealias Gateway = ConnectionGateway
}

/// Whether and how a connection goes through a Remote Desktop Gateway
/// (docs/DESIGN.md, RD Gateway), as `Connection.Gateway`. Kept while the
/// choice is Never, so that switching back finds it again.
public struct ConnectionGateway: Codable, Equatable, Sendable {
    /// Only Never and Always: Microsoft's "only when the computer cannot be
    /// reached directly" and "not for local addresses" are later steps.
    public enum Usage: String, Codable, Sendable, CaseIterable {
        case never
        case always
    }

    public enum SignIn: String, Codable, Sendable, CaseIterable {
        /// With the computer's user name and password.
        case sameAsComputer
        /// With `username` and `domain`, and a password of its own.
        case anotherAccount
    }

    public static let defaultPort = 443

    public var usage = Usage.never
    public var host = ""
    public var port = ConnectionGateway.defaultPort
    public var signIn = SignIn.sameAsComputer
    public var username = ""
    public var domain = ""

    public init(
        usage: Usage = .never, host: String = "", port: Int = ConnectionGateway.defaultPort,
        signIn: SignIn = .sameAsComputer, username: String = "", domain: String = ""
    ) {
        self.usage = usage
        self.host = host
        self.port = port
        self.signIn = signIn
        self.username = username
        self.domain = domain
    }

    /// Whether connecting goes through the gateway: Always, with an address.
    public var isUsed: Bool {
        usage == .always && !host.isEmpty
    }

    /// The address as typed in the editor: the host, and the port after a
    /// colon when it is not 443.
    public var address: String {
        RDPFileMapping.joinAddress(host: host, port: port, defaultPort: Self.defaultPort)
    }

    /// Splits `host`, `host:port`, `[v6]`, or `[v6]:port`. The port is nil
    /// when none was given.
    public static func split(address: String) -> (host: String, port: Int?) {
        RDPFileMapping.splitAddress(address)
    }

    enum CodingKeys: String, CodingKey {
        case usage, host, port, signIn, username, domain
    }

    /// Anything missing takes its default.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        usage = try values.decodeIfPresent(Usage.self, forKey: .usage) ?? usage
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        signIn = try values.decodeIfPresent(SignIn.self, forKey: .signIn) ?? signIn
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        domain = try values.decodeIfPresent(String.self, forKey: .domain) ?? domain
    }
}
