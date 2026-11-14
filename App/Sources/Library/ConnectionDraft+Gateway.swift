import Foundation
import VistaraCore

/// The Gateway section (docs/DESIGN.md, RD Gateway).
extension ConnectionDraft {
    var trimmedGatewayAddress: String { gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the gateway's address can't be used, or nil. Only while the
    /// connection uses a gateway: Never keeps whatever was typed.
    var gatewayProblem: String? {
        guard gatewayUsage == .always else { return nil }
        let address = trimmedGatewayAddress
        if address.isEmpty { return "Enter the gateway’s name or address." }
        if address.contains("://") || address.contains("/") {
            return "Enter only the gateway’s name, without “https://” or a path."
        }
        if address.contains(where: \.isWhitespace) { return "A gateway’s name can’t contain spaces." }
        if let port = Self.typedPort(in: address), !(1...65_535).contains(port) {
            return "Enter a port from 1 to 65535 after the colon."
        }
        return nil
    }

    /// What was typed after the last colon of `host:port` or `[v6]:port`: a
    /// number, or -1 when it is not one. Nil when there is no port.
    private static func typedPort(in address: String) -> Int? {
        let afterHost: Substring
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            afterHost = address[address.index(after: close)...]
        } else {
            let colons = address.filter { $0 == ":" }.count
            // More than one colon without brackets is an IPv6 address.
            guard colons == 1, let colon = address.firstIndex(of: ":") else { return nil }
            afterHost = address[colon...]
        }
        guard afterHost.hasPrefix(":") else { return nil }
        return Int(afterHost.dropFirst()) ?? -1
    }

    /// The gateway to save. Never keeps the address and account, so that
    /// switching back finds them.
    var gateway: Connection.Gateway {
        let address = trimmedGatewayAddress
        let split = Connection.Gateway.split(address: address)
        let user = LauncherInput.userAndDomain(gatewayUsername)
        let typedDomain = gatewayDomain.trimmingCharacters(in: .whitespaces)
        return Connection.Gateway(
            usage: gatewayUsage,
            host: split.host,
            port: split.port ?? Connection.Gateway.defaultPort,
            signIn: gatewaySignIn,
            username: user.username,
            domain: typedDomain.isEmpty ? user.domain ?? "" : typedDomain
        )
    }
}
