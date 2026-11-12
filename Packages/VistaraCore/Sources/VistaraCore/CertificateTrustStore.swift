import Foundation

/// A certificate the user chose to always trust for one computer. Only its
/// fingerprint is kept, never the certificate.
public struct TrustedCertificate: Codable, Equatable, Sendable, Identifiable {
    public var host: String
    public var port: UInt16
    /// SHA-256 as colon-separated lowercase hex pairs.
    public var fingerprint: String
    public var dateAdded: Date

    public var id: String { "\(host):\(port)" }
}

/// What the trust store knows about a certificate a computer presented.
public enum CertificateTrust: Equatable, Sendable {
    /// The user trusted exactly this certificate for this computer.
    case trusted
    /// Nothing is recorded for this computer.
    case unknown
    /// The user trusted a different certificate for this computer before.
    case changed(previousFingerprint: String)
}

/// The certificates the user chose to always trust, by host and port, in
/// `trusted-certificates.json`.
///
/// Errors lean towards asking again: a file that cannot be read is moved
/// aside and the store starts empty, so every computer is unknown once more.
/// Nothing here can make an unknown certificate count as trusted.
public final class CertificateTrustStore: Sendable {
    public static let fileName = "trusted-certificates.json"
    static let currentSchemaVersion = 1

    public enum StoreError: Error, Equatable {
        /// The file was written by a newer Vistara. It is left untouched and
        /// nothing can be added or removed.
        case newerSchema(found: Int)
    }

    private struct File: Codable {
        var schemaVersion: Int
        var certificates: [TrustedCertificate]
    }

    private struct State {
        var isLoaded = false
        var certificates: [String: TrustedCertificate] = [:]
        var newerSchema: Int?
        var corruptFileBackup: URL?
    }

    private let directory: URL
    private let lock = NSLock()
    private nonisolated(unsafe) var state = State()

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Where an unreadable file was moved to when the store was first read.
    public var corruptFileBackup: URL? {
        lock.withLock {
            loadIfNeeded()
            return state.corruptFileBackup
        }
    }

    /// Everything trusted, ordered by host and port.
    public var certificates: [TrustedCertificate] {
        lock.withLock {
            loadIfNeeded()
            return state.certificates.values.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
        }
    }

    public func trust(forHost host: String, port: UInt16, fingerprint: String) -> CertificateTrust {
        lock.withLock {
            loadIfNeeded()
            guard let known = state.certificates[Self.key(host, port)] else { return .unknown }
            return known.fingerprint == Self.normalized(fingerprint)
                ? .trusted : .changed(previousFingerprint: known.fingerprint)
        }
    }

    /// Records the certificate for the computer, replacing an earlier one.
    public func add(host: String, port: UInt16, fingerprint: String, date: Date = Date()) throws {
        try lock.withLock {
            loadIfNeeded()
            if let found = state.newerSchema { throw StoreError.newerSchema(found: found) }
            var certificates = state.certificates
            certificates[Self.key(host, port)] = TrustedCertificate(
                host: host.lowercased(), port: port, fingerprint: Self.normalized(fingerprint), dateAdded: date
            )
            try write(certificates)
            state.certificates = certificates
        }
    }

    /// Forgets the computer's certificate. The next connection asks again.
    public func remove(host: String, port: UInt16) throws {
        try lock.withLock {
            loadIfNeeded()
            if let found = state.newerSchema { throw StoreError.newerSchema(found: found) }
            var certificates = state.certificates
            guard certificates.removeValue(forKey: Self.key(host, port)) != nil else { return }
            try write(certificates)
            state.certificates = certificates
        }
    }

    // MARK: File

    private static func key(_ host: String, _ port: UInt16) -> String {
        "\(host.lowercased()):\(port)"
    }

    private static func normalized(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { !$0.isWhitespace }
    }

    /// Call with the lock held.
    private func loadIfNeeded() {
        guard !state.isLoaded else { return }
        state.isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.schemaVersion >= 1 else {
            state.corruptFileBackup = moveAsideCorruptFile()
            return
        }
        guard file.schemaVersion <= Self.currentSchemaVersion else {
            state.newerSchema = file.schemaVersion
            return
        }
        for certificate in file.certificates {
            var entry = certificate
            entry.host = entry.host.lowercased()
            entry.fingerprint = Self.normalized(entry.fingerprint)
            state.certificates[Self.key(entry.host, entry.port)] = entry
        }
    }

    private func write(_ certificates: [String: TrustedCertificate]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = File(
            schemaVersion: Self.currentSchemaVersion,
            certificates: certificates.values.sorted { $0.id < $1.id }
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try encoder.encode(file).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func moveAsideCorruptFile() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "trusted-certificates.corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString).json"
        let backup = directory.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}
