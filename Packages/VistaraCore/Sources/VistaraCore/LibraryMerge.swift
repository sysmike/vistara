import Foundation

/// A connection or folder as several Macs share it through a sync folder
/// (docs/DESIGN.md, Connections on several Macs).
protocol SyncedEntry: Equatable, Sendable {
    var id: UUID { get }
    var modifiedAt: Date? { get set }
    /// The entry as the folder keeps it: without what stays on each Mac.
    var shared: Self { get }
    /// The folder's version, with what stays on this Mac taken from `local`.
    func joined(with local: Self?) -> Self
}

extension Connection: SyncedEntry {
    /// Shared folders open only on the Mac whose bookmarks they hold, and the
    /// last use is each Mac's own.
    var shared: Connection {
        var shared = self
        shared.sharedFolders = []
        shared.lastConnectedAt = nil
        return shared
    }

    func joined(with local: Connection?) -> Connection {
        var joined = self
        joined.sharedFolders = local?.sharedFolders ?? []
        joined.lastConnectedAt = local?.lastConnectedAt
        return joined
    }
}

extension Folder: SyncedEntry {
    var shared: Folder { self }

    func joined(with local: Folder?) -> Folder { self }
}

/// What a sync folder holds: the latest version of each entry, and when each
/// deleted one went.
struct SyncFolderContents: Equatable, Sendable {
    var connections: [UUID: Connection] = [:]
    var folders: [UUID: Folder] = [:]
    var deletions: [UUID: Date] = [:]
}

/// Merges this Mac's library with a sync folder. Entry by entry, the later
/// change wins, all of it; a deletion wins over every change before it.
enum LibraryMerge {
    struct Outcome: Equatable {
        /// The library from now on, with what stays on this Mac.
        var library: Library
        /// Entries whose version here is newer than the folder's, as the
        /// folder keeps them.
        var connectionsToWrite: [Connection] = []
        var foldersToWrite: [Folder] = []
        /// Deletions the folder doesn't have yet.
        var deletionsToWrite: [UUID: Date] = [:]
        /// Entries deleted whose files are still in the folder.
        var filesToRemove: Set<UUID> = []
    }

    /// `localDeletions` are this Mac's deletions that may not have reached
    /// the folder yet.
    static func merge(local: Library, localDeletions: [UUID: Date], folder: SyncFolderContents) -> Outcome {
        var deletions = folder.deletions
        deletions.merge(localDeletions) { max($0, $1) }
        let connections = mergeEntries(local: local.connections, folder: folder.connections, deletions: deletions)
        let folders = mergeEntries(local: local.folders, folder: folder.folders, deletions: deletions)
        var library = local
        library.connections = connections.merged
        library.folders = folders.merged
        return Outcome(
            library: library,
            connectionsToWrite: connections.toWrite,
            foldersToWrite: folders.toWrite,
            deletionsToWrite: localDeletions.filter { id, date in (folder.deletions[id] ?? .distantPast) < date },
            filesToRemove: connections.toRemove.union(folders.toRemove)
        )
    }

    private struct EntryOutcome<Entry: SyncedEntry> {
        var merged: [Entry] = []
        var toWrite: [Entry] = []
        var toRemove: Set<UUID> = []
    }

    private static func mergeEntries<Entry: SyncedEntry>(
        local: [Entry], folder: [UUID: Entry], deletions: [UUID: Date]
    ) -> EntryOutcome<Entry> {
        var outcome = EntryOutcome<Entry>()
        let localIDs = Set(local.map(\.id))
        // This Mac's order first, then what only the folder has, in a stable order.
        let folderOnly = folder.values.filter { !localIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        for here in local {
            decide(here: here, there: folder[here.id], deletedAt: deletions[here.id], into: &outcome)
        }
        for there in folderOnly {
            decide(here: nil, there: there, deletedAt: deletions[there.id], into: &outcome)
        }
        return outcome
    }

    private static func decide<Entry: SyncedEntry>(
        here: Entry?, there: Entry?, deletedAt: Date?, into outcome: inout EntryOutcome<Entry>
    ) {
        let hereTime = here.map { $0.modifiedAt ?? .distantPast }
        let thereTime = there.map { $0.modifiedAt ?? .distantPast }
        // A tie goes to the folder, so every Mac decides the same way.
        let hereIsNewer = hereTime.map { mine in thereTime.map { mine > $0 } ?? true } ?? false
        let newest = max(hereTime ?? .distantPast, thereTime ?? .distantPast)
        if let deletedAt, deletedAt >= newest {
            if let there { outcome.toRemove.insert(there.id) }
            return
        }
        if hereIsNewer, let here {
            outcome.merged.append(here)
            if there != here.shared { outcome.toWrite.append(here.shared) }
        } else if let there {
            outcome.merged.append(there.joined(with: here))
        }
    }
}
