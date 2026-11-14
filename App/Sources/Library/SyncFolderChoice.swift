import Foundation

/// The folder chosen in Settings > Sync to keep the connections in
/// (docs/DESIGN.md, Connections on several Macs), kept as a security-scoped
/// bookmark so the sandboxed app can open it again after a relaunch.
struct SyncFolderChoice: Codable, Equatable, Sendable {
    var path: String
    var bookmark: Data

    static let defaultsKey = "SyncFolder"

    /// The choice for a folder the open panel returned.
    init(for url: URL) throws {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
        path = url.path
        bookmark = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    static func saved(in defaults: UserDefaults) -> SyncFolderChoice? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SyncFolderChoice.self, from: $0) }
    }

    func save(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    static func forget(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// The folder as it is now, opened: where its bookmark leads, and a new
    /// choice when it moved, as for shared folders. Nil when the bookmark
    /// leads nowhere, for example while its disk is unplugged.
    func open() -> (url: URL, moved: SyncFolderChoice?)? {
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        else { return nil }
        // Outside the sandbox, as in tests, there is no scope to start, and
        // the folder opens anyway.
        _ = url.startAccessingSecurityScopedResource()
        guard isStale || !SharedFolderAccess.isSamePlace(url, path) else { return (url, nil) }
        return (url, try? SyncFolderChoice(for: url))
    }

    /// The folder's name, as the Finder shows it.
    var name: String {
        FileManager.default.displayName(atPath: path)
    }

    /// Where the folder is: "iCloud Drive", or the name of the folder it is in.
    var location: String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        if parent.path.hasSuffix(Self.iCloudDriveSuffix) { return "iCloud Drive" }
        if path.contains(Self.iCloudDriveSuffix + "/") { return "iCloud Drive › \(parent.lastPathComponent)" }
        return FileManager.default.displayName(atPath: parent.path)
    }

    private static let iCloudDriveSuffix = "Mobile Documents/com~apple~CloudDocs"

    /// iCloud Drive's folder, where the open panel starts. The home folder
    /// is the user's, not the sandbox container's. The sandbox can't see
    /// whether it is there; without iCloud Drive the panel starts elsewhere.
    static var iCloudDrive: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
}
