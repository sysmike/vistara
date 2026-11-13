import Foundation

/// Loads and saves the connection library as one JSON file.
///
/// An actor, so saves never interleave. Writes are atomic: a crash leaves
/// either the old file or the new one.
public actor ConnectionStore {
    public struct LoadResult: Sendable {
        public var library: Library
        /// Set when the file could not be read. The unreadable file was moved
        /// here and the library starts empty; tell the user.
        public var corruptFileBackup: URL?
        /// Entries left out because they could not be read. The rest loaded.
        public var skippedEntries: [LibraryCodec.SkippedEntry] = []
        /// A copy of the file as it was, made when entries were left out, so
        /// the next save loses nothing for good; tell the user.
        public var originalFileCopy: URL?
    }

    public static let fileName = "connections.json"

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Vistara`, which resolves inside the
    /// app's container when sandboxed.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(VistaraCore.applicationSupportFolderName, isDirectory: true)
    }

    /// Returns an empty library when there is no file yet.
    ///
    /// Throws `LibraryCodec.CodecError.newerSchema` for a file written by a
    /// newer Vistara, which is left untouched. Any other unreadable file is
    /// moved aside and reported in the result.
    public func load() throws -> LoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LoadResult(library: Library(), corruptFileBackup: nil)
        }

        do {
            let read = try LibraryCodec.read(Data(contentsOf: fileURL))
            guard !read.skipped.isEmpty else {
                return LoadResult(library: read.library, corruptFileBackup: nil)
            }
            return LoadResult(
                library: read.library, corruptFileBackup: nil, skippedEntries: read.skipped,
                originalFileCopy: try copyAside(prefix: "connections.unreadable")
            )
        } catch let error as LibraryCodec.CodecError {
            if case .newerSchema = error { throw error }
            return LoadResult(library: Library(), corruptFileBackup: try moveAsideCorruptFile())
        } catch is DecodingError {
            return LoadResult(library: Library(), corruptFileBackup: try moveAsideCorruptFile())
        }
    }

    public func save(_ library: Library) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try LibraryCodec.encode(library).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func moveAsideCorruptFile() throws -> URL {
        let backup = asideURL(prefix: "connections.corrupt")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }

    /// Copies the file, which stays in place, next to it.
    private func copyAside(prefix: String) throws -> URL {
        let copy = asideURL(prefix: prefix)
        try FileManager.default.copyItem(at: fileURL, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return copy
    }

    /// A new file name next to the library, stamped with the time.
    private func asideURL(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let url = directory.appendingPathComponent("\(prefix)-\(stamp).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        return directory.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString).json")
    }
}
