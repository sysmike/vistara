import Foundation

/// The library as a sync folder keeps it (docs/DESIGN.md, Connections on
/// several Macs): in "Vistara Connections" inside the folder chosen, one file
/// per connection and per library folder, named by its identifier, and a
/// marker for each deleted one.
///
/// Every read and write goes through `NSFileCoordinator`, so a sync service
/// that hasn't downloaded a file yet fetches it first, and a file is never
/// read half written.
struct SyncFolder: Sendable {
    static let folderName = "Vistara Connections"
    /// The layout this Vistara writes. A folder written in a newer one is
    /// left alone.
    static let layout = 1
    /// How long a deletion marker stays, for Macs that were away.
    static let deletionsKept: TimeInterval = 90 * 24 * 60 * 60

    enum Problem: Error, Equatable {
        /// The chosen folder isn't there: not mounted, iCloud Drive off, gone.
        case unreachable
        /// Written by a newer Vistara: read nothing, write nothing.
        case newerLayout
    }

    /// What was read, with what needs tidying once merged.
    struct Reading {
        var contents = SyncFolderContents()
        /// Files that could not be read; they are left as they are.
        var damaged: [String] = []
        /// Copies a sync service made next to an entry's file, by entry.
        var copies: [UUID: [URL]] = [:]
        /// Deletion markers past `deletionsKept`.
        var expiredDeletions: [UUID] = []
    }

    private struct Layout: Codable {
        var layout: Int
        var schemaVersion: Int
    }

    private struct Deletion: Codable {
        var id: UUID
        var deletedAt: Date
    }

    let chosen: URL
    var root: URL { chosen.appendingPathComponent(Self.folderName, isDirectory: true) }
    private var connectionsFolder: URL { root.appendingPathComponent("connections", isDirectory: true) }
    private var foldersFolder: URL { root.appendingPathComponent("folders", isDirectory: true) }
    private var deletionsFolder: URL { root.appendingPathComponent("deleted", isDirectory: true) }
    private var layoutFile: URL { root.appendingPathComponent("layout.json") }

    // MARK: Reading

    /// Everything in the folder, creating it if needed.
    func read(now: Date) throws -> Reading {
        try prepare()
        var reading = Reading()
        reading.contents.connections = readEntries(Connection.self, in: connectionsFolder, into: &reading)
        reading.contents.folders = readEntries(Folder.self, in: foldersFolder, into: &reading)
        let decoder = Self.decoder()
        for file in readAll(in: deletionsFolder) {
            guard let deletion = try? decoder.decode(Deletion.self, from: file.data) else {
                reading.damaged.append(file.url.lastPathComponent)
                continue
            }
            if now.timeIntervalSince(deletion.deletedAt) > Self.deletionsKept {
                reading.expiredDeletions.append(deletion.id)
            } else {
                reading.contents.deletions[deletion.id] = deletion.deletedAt
            }
        }
        return reading
    }

    /// One version of a file: the file itself, a copy next to it, or one of
    /// iCloud Drive's conflict versions of it.
    private struct FileVersion {
        var url: URL
        var data: Data
        var isConflict = false
    }

    /// The newest version of each entry in a folder of the layout, noting
    /// copies that aren't the entry's own file.
    private func readEntries<Entry: SyncedEntry & UnknownFieldPreserving>(
        _ type: Entry.Type, in folder: URL, into reading: inout Reading
    ) -> [UUID: Entry] {
        var entries: [UUID: Entry] = [:]
        for file in readAll(in: folder) {
            for version in [file] + conflictVersions(of: file.url) {
                guard let entry = LibraryCodec.entry(type, from: version.data) else {
                    reading.damaged.append(version.url.lastPathComponent)
                    continue
                }
                if version.isConflict || version.url.deletingPathExtension().lastPathComponent != entry.id.uuidString {
                    reading.copies[entry.id, default: []].append(version.url)
                }
                let known = entries[entry.id].map { $0.modifiedAt ?? .distantPast }
                if let known, known >= entry.modifiedAt ?? .distantPast { continue }
                entries[entry.id] = entry
            }
        }
        return entries
    }

    /// Creates the folder's layout, or refuses one this Vistara can't write.
    func prepare() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw Problem.unreachable }
        if let data = coordinatedRead(layoutFile) {
            guard let layout = try? JSONDecoder().decode(Layout.self, from: data),
                layout.layout <= Self.layout, layout.schemaVersion <= LibraryCodec.currentSchemaVersion
            else { throw Problem.newerLayout }
            return
        }
        for folder in [root, connectionsFolder, foldersFolder, deletionsFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let layout = Layout(layout: Self.layout, schemaVersion: LibraryCodec.currentSchemaVersion)
        try coordinatedWrite(JSONEncoder().encode(layout), to: layoutFile)
    }

    /// The JSON files in a folder of the layout and what is in each. A file a
    /// sync service hasn't downloaded yet is read by its real name, which
    /// fetches it.
    private func readAll(in folder: URL) -> [FileVersion] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var files: [FileVersion] = []
        for name in names.sorted() {
            var fileName = name
            // Older iCloud Drive keeps ".<name>.icloud" in place of a file not downloaded.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                fileName = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: folder.appendingPathComponent(fileName)
                )
            }
            guard fileName.hasSuffix(".json"), !fileName.hasPrefix(".") else { continue }
            let url = folder.appendingPathComponent(fileName)
            if let data = coordinatedRead(url) { files.append(FileVersion(url: url, data: data)) }
        }
        return files
    }

    private func conflictVersions(of url: URL) -> [FileVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).compactMap { version in
            (try? Data(contentsOf: version.url)).map { FileVersion(url: version.url, data: $0, isConflict: true) }
        }
    }

    /// The names and modification dates of everything in the folder's layout.
    typealias Fingerprint = [String: Date]

    /// What the folder holds now, to notice a change without reading it.
    /// Empty when it can't be reached.
    func fingerprint() -> Fingerprint {
        var fingerprint = Fingerprint()
        for folder in [root, connectionsFolder, foldersFolder, deletionsFolder] {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for item in items {
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                fingerprint[item.path] = date ?? .distantPast
            }
        }
        return fingerprint
    }

    // MARK: Writing

    func write(_ connection: Connection) throws {
        try coordinatedWrite(LibraryCodec.entryData(connection), to: file(for: connection.id, in: connectionsFolder))
    }

    func write(_ folder: Folder) throws {
        try coordinatedWrite(LibraryCodec.entryData(folder), to: file(for: folder.id, in: foldersFolder))
    }

    /// Marks an entry deleted, and removes its file.
    func writeDeletion(of id: UUID, at date: Date) throws {
        try coordinatedWrite(
            Self.encoder().encode(Deletion(id: id, deletedAt: date)), to: file(for: id, in: deletionsFolder)
        )
        removeEntryFiles(of: id)
    }

    func removeEntryFiles(of id: UUID) {
        coordinatedRemove(file(for: id, in: connectionsFolder))
        coordinatedRemove(file(for: id, in: foldersFolder))
    }

    func removeDeletion(of id: UUID) {
        coordinatedRemove(file(for: id, in: deletionsFolder))
    }

    /// Removes copies a sync service made, once their entry is merged, and
    /// marks iCloud Drive's conflict versions resolved.
    func removeCopies(_ copies: [URL], of id: UUID) {
        for copy in copies where copy.path.hasPrefix(root.path) {
            coordinatedRemove(copy)
        }
        let own = file(for: id, in: connectionsFolder)
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: own), !versions.isEmpty else { return }
        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: own)
    }

    private func file(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Coordination

    private func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var error: NSError?
        var writeError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let failure = error ?? writeError { throw failure }
    }

    private func coordinatedRemove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
