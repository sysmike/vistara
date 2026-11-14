import Foundation

/// The library kept in a sync folder that several Macs share
/// (docs/DESIGN.md, Connections on several Macs), with this Mac's library
/// file as what it last saw.
///
/// Saving stamps each entry whose shared part changed and notes deletions,
/// keeps the library here, and writes it to the folder when the folder can
/// be reached; `sync()` also takes what other Macs changed. While the folder
/// can't be reached, everything works on this Mac's copy, and the changes
/// made meanwhile are written when it is back.
public actor SyncedLibraryStore {
    public enum FolderState: Sendable, Equatable {
        case reachable
        /// Not there now: changes wait on this Mac.
        case unreachable
        /// Written by a newer Vistara: nothing is read from it or written to it.
        case newerLayout
    }

    public struct SyncResult: Sendable, Equatable {
        /// The library from now on, with what stays on this Mac.
        public var library: Library
        public var folder: FolderState
        /// Files in the folder that could not be read; they were left as they are.
        public var damagedFiles: [String]
    }

    /// What must survive a relaunch: deletions the folder may not have yet.
    private struct State: Codable {
        var pendingDeletions: [UUID: Date] = [:]
    }

    public static let stateFileName = "sync-state.json"

    private let local: ConnectionStore
    private let folder: SyncFolder
    private let stateFile: URL
    private let now: @Sendable () -> Date
    private var known = Library()
    private var pendingDeletions: [UUID: Date] = [:]
    /// The folder as the last sync left it, to notice when it changes.
    private var seen: SyncFolder.Fingerprint?
    private var lastState: FolderState?

    /// `localDirectory` holds this Mac's library file; `folder` is the folder
    /// chosen, in which "Vistara Connections" is kept.
    public init(localDirectory: URL, folder: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        local = ConnectionStore(directory: localDirectory)
        self.folder = SyncFolder(chosen: folder)
        stateFile = localDirectory.appendingPathComponent(Self.stateFileName)
        // In whole seconds, as the files keep dates: a stamp kept finer here
        // would always be newer than its own copy in the folder.
        self.now = { Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)) }
    }

    /// This Mac's copy as last seen, to show at once; `sync()` follows.
    public func load() async throws -> ConnectionStore.LoadResult {
        let result = try await local.load()
        known = result.library
        pendingDeletions = readState().pendingDeletions
        return result
    }

    /// Saves a changed library here and, if it can, to the folder.
    ///
    /// Pass the library this store returned last, changed: an entry missing
    /// from it counts as deleted, on every Mac.
    @discardableResult
    public func save(_ library: Library) async throws -> SyncResult {
        let stamped = stamp(library)
        try await local.save(stamped)
        known = stamped
        try writeState()
        return try await sync()
    }

    /// Saves a library changed from `base`, which this store returned
    /// earlier: only what changed since `base` is this Mac's change, and
    /// what other Macs changed meanwhile stays.
    @discardableResult
    public func save(_ library: Library, basedOn base: Library) async throws -> SyncResult {
        try await save(LibraryMerge.rebase(library, from: base, onto: known))
    }

    /// Starts keeping the library in the folder, as when it is chosen: this
    /// Mac's entries are added to what is there, and nothing is deleted on
    /// either side, not even what the folder marks deleted.
    public func join() async throws -> SyncResult {
        pendingDeletions = [:]
        if let deletions = try? folder.read(now: now()).contents.deletions {
            let time = now()
            known.connections = known.connections.map { Self.restamp($0, ifIn: deletions, at: time) }
            known.folders = known.folders.map { Self.restamp($0, ifIn: deletions, at: time) }
            try await local.save(known)
        }
        try writeState()
        return try await sync()
    }

    private static func restamp<Entry: SyncedEntry>(
        _ entry: Entry, ifIn deletions: [UUID: Date], at time: Date
    ) -> Entry {
        guard deletions[entry.id] != nil else { return entry }
        var stamped = entry
        stamped.modifiedAt = time
        return stamped
    }

    /// Whether `sync()` may find something new: the folder changed since the
    /// last one, or that one couldn't finish. Cheap: it only lists the folder.
    public func needsSync() -> Bool {
        lastState != .reachable || folder.fingerprint() != seen
    }

    /// Identifiers in copies of this Mac's library file kept next to it.
    public func identifiersInKeptCopies() async -> Set<String> {
        await local.identifiersInKeptCopies()
    }

    /// Takes what other Macs changed and writes what this Mac changed.
    public func sync() async throws -> SyncResult {
        let reading: SyncFolder.Reading
        do {
            reading = try folder.read(now: now())
        } catch SyncFolder.Problem.newerLayout {
            return finish(SyncResult(library: known, folder: .newerLayout, damagedFiles: []))
        } catch {
            return finish(SyncResult(library: known, folder: .unreachable, damagedFiles: []))
        }
        let outcome = LibraryMerge.merge(local: known, localDeletions: pendingDeletions, folder: reading.contents)
        var state = FolderState.reachable
        do {
            try apply(outcome, tidying: reading)
            pendingDeletions = [:]
        } catch {
            // Written in part: what is left is written next time.
            state = .unreachable
        }
        if outcome.library != known {
            try await local.save(outcome.library)
            known = outcome.library
        }
        try writeState()
        return finish(SyncResult(library: known, folder: state, damagedFiles: reading.damaged))
    }

    private func finish(_ result: SyncResult) -> SyncResult {
        lastState = result.folder
        seen = folder.fingerprint()
        return result
    }

    private func apply(_ outcome: LibraryMerge.Outcome, tidying reading: SyncFolder.Reading) throws {
        for connection in outcome.connectionsToWrite { try folder.write(connection) }
        for libraryFolder in outcome.foldersToWrite { try folder.write(libraryFolder) }
        for (id, date) in outcome.deletionsToWrite { try folder.writeDeletion(of: id, at: date) }
        for id in outcome.filesToRemove { folder.removeEntryFiles(of: id) }
        // The winner of an entry with copies goes to its own file; the copies go.
        for (id, copies) in reading.copies {
            if let connection = outcome.library.connections.first(where: { $0.id == id }) {
                try folder.write(connection.shared)
            } else if let libraryFolder = outcome.library.folders.first(where: { $0.id == id }) {
                try folder.write(libraryFolder.shared)
            }
            folder.removeCopies(copies, of: id)
        }
        for id in reading.expiredDeletions { folder.removeDeletion(of: id) }
    }

    // MARK: Changes on this Mac

    /// The library with every entry whose shared part changed since it was
    /// last seen stamped now, and the entries gone noted as deleted.
    private func stamp(_ library: Library) -> Library {
        let time = now()
        var stamped = library
        let knownConnections = Dictionary(known.connections.map { ($0.id, $0) }) { first, _ in first }
        let knownFolders = Dictionary(known.folders.map { ($0.id, $0) }) { first, _ in first }
        stamped.connections = library.connections.map { Self.stamp($0, was: knownConnections[$0.id], at: time) }
        stamped.folders = library.folders.map { Self.stamp($0, was: knownFolders[$0.id], at: time) }
        let present = Set(library.connections.map(\.id)).union(library.folders.map(\.id))
        for id in Set(knownConnections.keys).union(knownFolders.keys) where !present.contains(id) {
            pendingDeletions[id] = time
        }
        // Back again, as after an undo: no longer deleted.
        for id in present { pendingDeletions[id] = nil }
        return stamped
    }

    private static func stamp<Entry: SyncedEntry>(_ entry: Entry, was old: Entry?, at time: Date) -> Entry {
        if let old, entry.hasSameSharedPart(as: old) { return entry }
        var stamped = entry
        stamped.modifiedAt = time
        return stamped
    }

    // MARK: State

    private func readState() -> State {
        guard let data = try? Data(contentsOf: stateFile),
            let state = try? SyncFolder.decoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func writeState() throws {
        try FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try SyncFolder.encoder().encode(State(pendingDeletions: pendingDeletions))
        try data.write(to: stateFile, options: .atomic)
    }
}
