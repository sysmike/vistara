import Foundation

/// What the temporary launcher's text fields mean.
enum LauncherInput {
    static let defaultPort: UInt16 = 3389

    /// Splits "host" or "host:port". Returns nil when there is no host or the
    /// port is not a number between 1 and 65535. A bare IPv6 address is taken
    /// as a host; "[address]:port" gives it a port.
    static func hostAndPort(_ text: String) -> (host: String, port: UInt16)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") { return bracketed(trimmed) }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return (trimmed, defaultPort)
        case 2:
            guard !parts[0].isEmpty, let port = parsePort(parts[1]) else { return nil }
            return (String(parts[0]), port)
        default:
            return (trimmed, defaultPort)
        }
    }

    /// Splits "DOMAIN\user". Anything else is a user name without a domain.
    static func userAndDomain(_ text: String) -> (username: String, domain: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return (trimmed, nil) }
        return (String(parts[1]), String(parts[0]))
    }

    /// "[address]" or "[address]:port".
    private static func bracketed(_ text: String) -> (host: String, port: UInt16)? {
        guard let close = text.firstIndex(of: "]") else { return nil }
        let host = String(text[text.index(after: text.startIndex)..<close])
        let rest = text[text.index(after: close)...]
        guard !host.isEmpty else { return nil }
        if rest.isEmpty { return (host, defaultPort) }
        guard rest.hasPrefix(":"), let port = parsePort(rest.dropFirst()) else { return nil }
        return (host, port)
    }

    private static func parsePort(_ text: Substring) -> UInt16? {
        guard let port = UInt16(text), port > 0 else { return nil }
        return port
    }
}
