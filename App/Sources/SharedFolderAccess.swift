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
    /// Folders that were moved or renamed since their bookmark was made, with
    /// a fresh bookmark and their new path, for the saved connection.
    private(set) var renewed: [Renewal] = []
    private var opened: [URL] = []
    private static let log = RDPLogging.logger("folders")

    /// A shared folder as it was saved, and as it should be saved now.
    struct Renewal: Equatable {
        var old: Connection.SharedFolder
        var new: Connection.SharedFolder
    }

    init(_ shared: [Connection.SharedFolder]) {
        var names = Set<String>()
        for folder in shared {
            guard let resolved = Self.resolveNoting(folder) else {
                Self.log.warning("A shared folder cannot be found and is not shared: \(folder.path, privacy: .private)")
                missing.append(folder)
                continue
            }
            let url = resolved.url
            if url.startAccessingSecurityScopedResource() {
                opened.append(url)
            }
            if resolved.isStale || !Self.isSamePlace(url, folder.path) {
                renew(folder, at: url)
            }
            let name = Self.driveName(for: url, avoiding: &names)
            folders.append(RDPSharedFolder(name: name, path: url.path, isReadOnly: folder.isReadOnly))
        }
    }

    /// Makes a new bookmark while the folder is open. A stale bookmark still
    /// works today, but may stop resolving after the folder moves again.
    private func renew(_ folder: Connection.SharedFolder, at url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            let new = Connection.SharedFolder(path: url.path, bookmark: bookmark, isReadOnly: folder.isReadOnly)
            renewed.append(Renewal(old: folder, new: new))
            Self.log.info("Renewed the bookmark of a moved shared folder: \(url.path, privacy: .private)")
        } catch {
            Self.log.warning("A moved shared folder's bookmark cannot be renewed: \(error.localizedDescription)")
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
        resolveNoting(folder)?.url
    }

    /// Whether a resolved folder is where the saved path says. A bookmark may
    /// resolve through a symbolic link, such as /var for /private/var.
    static func isSamePlace(_ url: URL, _ path: String) -> Bool {
        url.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The folder a saved bookmark leads to, and whether the bookmark should
    /// be made again.
    private static func resolveNoting(_ folder: Connection.SharedFolder) -> (url: URL, isStale: Bool)? {
        guard let bookmark = folder.bookmark else { return nil }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ),
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return (url, isStale)
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
