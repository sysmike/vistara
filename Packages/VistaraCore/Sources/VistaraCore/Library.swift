import Foundation

/// A model that keeps fields it does not recognize, so that a file written by
/// a newer Vistara survives being saved by this one.
protocol UnknownFieldPreserving: Codable {
    static var knownKeys: Set<String> { get }
    var unknownFields: [String: JSONValue] { get set }
}

/// A folder in the sidebar. Folders do not nest.
public struct Folder: Identifiable, Equatable, Sendable, UnknownFieldPreserving {
    public var id: UUID
    public var name: String
    public var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name
    }

    public static var knownKeys: Set<String> {
        Set(CodingKeys.allCases.map(\.stringValue))
    }

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything the connections file holds.
public struct Library: Equatable, Sendable {
    public var connections: [Connection]
    public var folders: [Folder]
    public var unknownFields: [String: JSONValue] = [:]

    public init(connections: [Connection] = [], folders: [Folder] = []) {
        self.connections = connections
        self.folders = folders
    }
}

/// Reads and writes the versioned JSON form of a `Library`.
public enum LibraryCodec {
    public static let currentSchemaVersion = 1

    public enum CodecError: Error, Equatable {
        case notAnObject
        case missingSchemaVersion
        /// The file was written by a newer Vistara. It must not be overwritten.
        case newerSchema(found: Int, supported: Int)
        case noMigration(from: Int)
    }

    /// Rewrites the file's top-level object from one schema version to the next.
    typealias Migration = @Sendable (inout [String: JSONValue]) -> Void

    /// Keyed by the version a migration starts from. Empty while version 1 is
    /// the only schema.
    static let migrations: [Int: Migration] = [:]

    private static let rootKeys: Set<String> = ["schemaVersion", "connections", "folders"]

    public static func decode(_ data: Data) throws -> Library {
        try decode(data, migrations: migrations, currentVersion: currentSchemaVersion)
    }

    static func decode(_ data: Data, migrations: [Int: Migration], currentVersion: Int) throws -> Library {
        guard case .object(var root) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CodecError.notAnObject
        }
        guard case .integer(let storedVersion)? = root["schemaVersion"] else {
            throw CodecError.missingSchemaVersion
        }

        var version = Int(storedVersion)
        guard version <= currentVersion else {
            throw CodecError.newerSchema(found: version, supported: currentVersion)
        }
        while version < currentVersion {
            guard let migrate = migrations[version] else {
                throw CodecError.noMigration(from: version)
            }
            migrate(&root)
            version += 1
        }

        var library = Library()
        library.connections = try models(Connection.self, in: root["connections"])
        library.folders = try models(Folder.self, in: root["folders"])
        library.unknownFields = root.filter { !rootKeys.contains($0.key) && !isSecretLike($0.key) }
        return library
    }

    public static func encode(_ library: Library) throws -> Data {
        var root = library.unknownFields.filter { !isSecretLike($0.key) }
        root["schemaVersion"] = .integer(Int64(currentSchemaVersion))
        root["connections"] = .array(try library.connections.map(value(of:)))
        root["folders"] = .array(try library.folders.map(value(of:)))

        let encoder = JSONEncoder()
        // Stable output keeps the file readable and diffs small.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSONValue.object(root))
    }

    /// Unknown fields with names like these are dropped instead of preserved,
    /// so the file can never carry a secret through a load and save cycle.
    static func isSecretLike(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return ["password", "passwd", "secret", "credential", "token"].contains { lowercased.contains($0) }
    }

    private static func modelDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func modelEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func models<Model: UnknownFieldPreserving>(
        _ type: Model.Type,
        in value: JSONValue?
    ) throws -> [Model] {
        guard case .array(let items)? = value else { return [] }
        return try items.map { item in
            var model = try modelDecoder().decode(Model.self, from: JSONEncoder().encode(item))
            if case .object(let fields) = item {
                model.unknownFields = fields.filter { !Model.knownKeys.contains($0.key) && !isSecretLike($0.key) }
            }
            return model
        }
    }

    private static func value<Model: UnknownFieldPreserving>(of model: Model) throws -> JSONValue {
        let encoded = try JSONDecoder().decode(JSONValue.self, from: modelEncoder().encode(model))
        guard case .object(var fields) = encoded else { return encoded }
        for (key, value) in model.unknownFields where fields[key] == nil && !isSecretLike(key) {
            fields[key] = value
        }
        return .object(fields)
    }
}
