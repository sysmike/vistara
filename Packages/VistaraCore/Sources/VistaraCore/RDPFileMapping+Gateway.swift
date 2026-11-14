import Foundation

/// The gateway in `.rdp` files, as the Microsoft client writes it:
/// `gatewayhostname` (with a port after a colon), `gatewayusagemethod`,
/// `gatewaycredentialssource`, and `promptcredentialonce`. The gateway's user
/// name goes in `gatewayusername`, which FreeRDP and other clients read too.
extension RDPFileMapping {
    static let gatewayKeys: Set<String> = [
        "gatewayhostname", "gatewayusagemethod", "gatewaycredentialssource", "promptcredentialonce", "gatewayusername"
    ]

    /// `gatewayusagemethod` values (TSC_PROXY_MODE_*). 4 is not used either,
    /// like 0.
    private enum UsageMethod {
        static let never = 0
        static let always = 1
        /// Only when the computer cannot be reached directly, and never for
        /// local addresses.
        static let detect = 2
        /// The gateway settings of the Mac's administrator (group policy).
        static let systemDefault = 3
    }

    /// Whether the file uses its gateway only sometimes, which Vistara does
    /// not: it uses it always, and the import notice says so.
    public static func usesGatewayOnlySometimes(_ file: RDPFile) -> Bool {
        guard let method = file.integer("gatewayusagemethod") else { return false }
        return [UsageMethod.detect, UsageMethod.systemDefault].contains(method) && gatewayAddress(in: file) != nil
    }

    private static func gatewayAddress(in file: RDPFile) -> String? {
        guard let address = file.string("gatewayhostname")?.trimmingCharacters(in: .whitespaces), !address.isEmpty
        else { return nil }
        return address
    }

    static func applyGateway(of file: RDPFile, to connection: inout Connection) {
        var gateway = Connection.Gateway()
        if let address = gatewayAddress(in: file) {
            let (host, port) = splitAddress(address)
            gateway.host = host
            gateway.port = port ?? Connection.Gateway.defaultPort
        }
        if let method = file.integer("gatewayusagemethod") {
            let always = [UsageMethod.always, UsageMethod.detect, UsageMethod.systemDefault].contains(method)
            gateway.usage = always ? .always : .never
        } else {
            // No usage method: a gateway named is meant to be used.
            gateway.usage = .always
        }
        if gateway.host.isEmpty { gateway.usage = .never }

        let (domain, username) = splitUsername(file.string("gatewayusername") ?? "")
        gateway.username = username
        gateway.domain = domain
        // "Use my Remote Desktop Gateway credentials for the remote computer".
        if let once = file.integer("promptcredentialonce") {
            gateway.signIn = once == 0 ? .anotherAccount : .sameAsComputer
        } else {
            gateway.signIn = username.isEmpty ? .sameAsComputer : .anotherAccount
        }
        connection.gateway = gateway
    }

    /// Nothing for a connection that never had a gateway. One whose gateway
    /// is set to Never keeps its address, marked as not used.
    static func gatewaySettings(of connection: Connection) -> [RDPFile.Setting] {
        let gateway = connection.gateway
        guard !gateway.host.isEmpty else { return [] }
        var settings: [RDPFile.Setting] = [
            .init(key: "gatewayhostname", value: .string(gateway.address)),
            .init(
                key: "gatewayusagemethod",
                value: .integer(gateway.usage == .always ? UsageMethod.always : UsageMethod.never)
            ),
            // Sign in with a user name and password: smart cards are not offered.
            .init(key: "gatewaycredentialssource", value: .integer(0)),
            .init(key: "promptcredentialonce", value: .integer(gateway.signIn == .sameAsComputer ? 1 : 0))
        ]
        if gateway.signIn == .anotherAccount, !gateway.username.isEmpty {
            let user = gateway.domain.isEmpty ? gateway.username : "\(gateway.domain)\\\(gateway.username)"
            settings.append(.init(key: "gatewayusername", value: .string(user)))
        }
        return settings
    }
}
