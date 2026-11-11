import Foundation

/// Converts between `.rdp` files and connections.
public enum RDPFileMapping {
    public enum ImportError: Error, Equatable {
        /// The file has no `full address`, so there is nothing to connect to.
        case missingAddress
    }

    /// Keys Vistara understands. Everything else is kept in
    /// `Connection.additionalRDPSettings`.
    static let mappedKeys: Set<String> = [
        "full address", "server port", "username", "domain",
        "desktopwidth", "desktopheight", "smart sizing", "dynamic resolution", "desktopscalefactor",
        "redirectclipboard", "audiomode", "autoreconnection enabled",
        "enablecredsspsupport", "authentication level"
    ]

    /// Builds a connection from a file. The file format has no name, so the
    /// caller supplies one, usually the file name.
    public static func connection(from file: RDPFile, name: String) throws -> Connection {
        guard let address = file.string("full address")?.trimmingCharacters(in: .whitespaces), !address.isEmpty
        else { throw ImportError.missingAddress }

        let (host, addressPort) = splitAddress(address)
        var connection = Connection(name: name, host: host)
        connection.port = addressPort ?? file.integer("server port") ?? Connection.defaultPort

        let (domain, username) = splitUsername(file.string("username") ?? "")
        connection.username = username
        connection.domain = file.string("domain").flatMap { $0.isEmpty ? nil : $0 } ?? domain

        applyDisplaySettings(of: file, to: &connection)
        applyDeviceAndSecuritySettings(of: file, to: &connection)

        connection.additionalRDPSettings = file.settings.filter { !mappedKeys.contains($0.key) }.map(\.line)
        return connection
    }

    private static func applyDisplaySettings(of file: RDPFile, to connection: inout Connection) {
        if let width = file.integer("desktopwidth"), let height = file.integer("desktopheight") {
            connection.fixedWidth = width
            connection.fixedHeight = height
            connection.resolutionMode = .fixed
        }
        if file.integer("smart sizing") == 1 { connection.resolutionMode = .scaleToFit }
        if file.integer("dynamic resolution") == 1 { connection.resolutionMode = .matchWindow }
        if let scale = file.integer("desktopscalefactor") { connection.usesHiDPI = scale > 100 }
    }

    private static func applyDeviceAndSecuritySettings(of file: RDPFile, to connection: inout Connection) {
        if let clipboard = file.integer("redirectclipboard") { connection.sharesClipboard = clipboard != 0 }
        switch file.integer("audiomode") {
        case 1: connection.audioMode = .playOnRemote
        case 2: connection.audioMode = .off
        default: connection.audioMode = .playOnThisMac
        }
        if let reconnect = file.integer("autoreconnection enabled") {
            connection.reconnectsAutomatically = reconnect != 0
        }
        if let credSSP = file.integer("enablecredsspsupport") { connection.requiresNLA = credSSP != 0 }
        // Level 0 means "connect without warning" in the Microsoft client.
        // Vistara never skips certificate checks silently, so every level
        // other than 1 ("do not connect") becomes ask-on-first-use.
        connection.certificatePolicy = file.integer("authentication level") == 1 ? .requireTrusted : .askOnFirstUse
    }

    /// Builds a file from a connection. The result never contains a password.
    public static func file(from connection: Connection) -> RDPFile {
        var settings: [RDPFile.Setting] = []
        func add(_ key: String, _ value: RDPFile.Value) {
            settings.append(.init(key: key, value: value))
        }
        func flag(_ isOn: Bool) -> RDPFile.Value { .integer(isOn ? 1 : 0) }

        add("full address", .string(joinAddress(host: connection.host, port: connection.port)))
        if !connection.username.isEmpty { add("username", .string(connection.username)) }
        if !connection.domain.isEmpty { add("domain", .string(connection.domain)) }

        if connection.resolutionMode == .fixed {
            add("desktopwidth", .integer(connection.fixedWidth))
            add("desktopheight", .integer(connection.fixedHeight))
        }
        add("smart sizing", flag(connection.resolutionMode == .scaleToFit))
        add("dynamic resolution", flag(connection.resolutionMode == .matchWindow))
        add("desktopscalefactor", .integer(connection.usesHiDPI ? 200 : 100))

        add("redirectclipboard", flag(connection.sharesClipboard))
        switch connection.audioMode {
        case .playOnThisMac: add("audiomode", .integer(0))
        case .playOnRemote: add("audiomode", .integer(1))
        case .off: add("audiomode", .integer(2))
        }
        add("autoreconnection enabled", flag(connection.reconnectsAutomatically))
        add("enablecredsspsupport", flag(connection.requiresNLA))
        add("authentication level", .integer(connection.certificatePolicy == .requireTrusted ? 1 : 2))

        let extras = connection.additionalRDPSettings
            .compactMap(RDPFile.Setting.init(line:))
            .filter { !mappedKeys.contains($0.key) }
        // RDPFile's initializer removes any password line.
        return RDPFile(settings: settings + extras)
    }

    /// Splits `host`, `host:port`, `[v6]`, `[v6]:port`, or a bare IPv6 address.
    static func splitAddress(_ address: String) -> (host: String, port: Int?) {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<close])
            let rest = address[address.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        return (address, nil)
    }

    static func joinAddress(host: String, port: Int) -> String {
        if port == Connection.defaultPort { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Splits `DOMAIN\user`. A `user@domain` name is left whole.
    static func splitUsername(_ username: String) -> (domain: String, username: String) {
        guard let separator = username.firstIndex(of: "\\") else { return ("", username) }
        return (String(username[..<separator]), String(username[username.index(after: separator)...]))
    }
}
