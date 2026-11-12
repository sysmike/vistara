import Foundation
import os
import RDPKit
import VistaraCore

/// Opens one session's shared folders inside the App Sandbox, through the
/// security-scoped bookmarks saved when the user chose them, and keeps them
/// open until the session ends.
final class SharedFolderAccess {
    /// What the session shares: the folders that could be opened.
    private(set) var folders: [RDPSharedFolder] = []
    /// Folders whose bookmark leads nowhere any more, for example because the
    /// folder was deleted. They are not shared.
    private(set) var missing: [Connection.SharedFolder] = []
    private var opened: [URL] = []
    private static let log = RDPLogging.logger("folders")

    init(_ shared: [Connection.SharedFolder]) {
        var names = Set<String>()
        for folder in shared {
            guard let url = Self.resolve(folder) else {
                Self.log.warning("A shared folder cannot be found and is not shared: \(folder.path, privacy: .private)")
                missing.append(folder)
                continue
            }
            if url.startAccessingSecurityScopedResource() {
                opened.append(url)
            }
            let name = Self.driveName(for: url, avoiding: &names)
            folders.append(RDPSharedFolder(name: name, path: url.path, isReadOnly: folder.isReadOnly))
        }
    }

    deinit {
        stop()
    }

    /// Ends access to the folders. The session must have ended.
    func stop() {
        for url in opened {
            url.stopAccessingSecurityScopedResource()
        }
        opened = []
    }

    /// The folder a saved bookmark leads to, or nil.
    static func resolve(_ folder: Connection.SharedFolder) -> URL? {
        guard let bookmark = folder.bookmark else { return nil }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ),
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return url
    }

    /// A folder to share, from a URL the open panel returned, with a bookmark
    /// that keeps access to it across launches.
    static func sharedFolder(for url: URL, readOnly: Bool = false) throws -> Connection.SharedFolder {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        return Connection.SharedFolder(path: url.path, bookmark: bookmark, isReadOnly: readOnly)
    }

    /// The drive's name on the remote computer: the folder's name, made
    /// unique among the session's drives.
    static func driveName(for url: URL, avoiding names: inout Set<String>) -> String {
        let base = url.lastPathComponent.isEmpty || url.path == "/" ? "Mac" : url.lastPathComponent
        var name = base
        var number = 2
        while names.contains(name.lowercased()) {
            name = "\(base) \(number)"
            number += 1
        }
        names.insert(name.lowercased())
        return name
    }
}
