import Foundation

extension Connection {
    public typealias Program = ConnectionProgram
}

/// Whether a connection opens the remote desktop or one program of the
/// remote computer (docs/DESIGN.md, RemoteApp), as `Connection.Program`.
/// Kept while the choice is The Desktop, so that switching back finds it
/// again.
public struct ConnectionProgram: Codable, Equatable, Sendable {
    public enum Opens: String, Codable, Sendable, CaseIterable {
        case desktop
        case program
    }

    public var opens = Opens.desktop
    /// The program as the remote computer publishes it: `||ALIAS` for a
    /// published program, or a path.
    public var path = ""
    /// Passed to the program when it starts; may be empty.
    public var arguments = ""

    public init(opens: Opens = .desktop, path: String = "", arguments: String = "") {
        self.opens = opens
        self.path = path
        self.arguments = arguments
    }

    /// Whether the connection opens a program: A Program, with one named.
    public var isUsed: Bool {
        opens == .program && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case opens, path, arguments
    }

    /// Anything missing takes its default.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        opens = try values.decodeIfPresent(Opens.self, forKey: .opens) ?? opens
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? path
        arguments = try values.decodeIfPresent(String.self, forKey: .arguments) ?? arguments
    }
}
