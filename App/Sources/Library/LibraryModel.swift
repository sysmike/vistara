import Foundation
import Observation
import RDPKit
import VistaraCore

/// The connection library as the connections window shows it: what is saved,
/// which part of it the sidebar selects, and what the search finds.
@MainActor
@Observable
final class LibraryModel {
    enum SidebarItem: Hashable {
        case all
        case favorites
        case recents
        case folder(UUID)
        case tag(String)
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        /// The file exists but cannot be used. Nothing is saved over it.
        case unreadable(String)
    }

    // Set by this type and its extensions only; see LibraryModel+Organizing.
    var library = Library()
    private(set) var loadState = LoadState.loading
    /// Where an unreadable file was moved before starting a new library.
    private(set) var corruptFileBackup: URL?
    /// Entries of the file that could not be read and were left out.
    private(set) var skippedEntries: [LibraryCodec.SkippedEntry] = []
    /// The file as it was, copied before the next save leaves those entries out.
    private(set) var originalFileCopy: URL?
    /// Identifiers in the copies of the file kept next to it, whose
    /// passwords stay while a copy holds them (#84).
    @ObservationIgnored private(set) var identifiersInKeptCopies: Set<String> = []
    /// Whether the notice about left-out entries still shows.
    var showsSkippedNotice = false
    /// What the last import did, shown until closed.
    var importReport: ImportReport?
    /// Set to show the open panel for File > Import.
    var isImporting = false
    /// Set to show the save panel for File > Export.
    var isExporting = false
    /// Files opened from the Finder before the library had loaded.
    @ObservationIgnored var pendingImports: [URL] = []
    /// Set when the last change could not be saved.
    private(set) var saveFailed = false

    /// What the editor sheet shows, if it is open.
    enum EditorRequest: Identifiable, Equatable {
        case new
        case edit(Connection.ID)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let id): id.uuidString
            }
        }
    }

    var editorRequest: EditorRequest?
    /// The rows selected in the table.
    var selectedIDs = Set<Connection.ID>()

    var selection = SidebarItem.all {
        didSet {
            // Recents are ordered by last use until someone sorts otherwise.
            if selection == .recents, oldValue != .recents { sortOrder = [Self.lastUsedFirst] }
        }
    }
    /// The folder whose name is being edited in the sidebar.
    var renamingFolderID: Folder.ID?

    static let lastUsedFirst = KeyPathComparator(\Connection.lastUsedSortKey, order: .reverse)
    /// How many connections Recents shows.
    static let recentsLimit = 20
    var searchText = ""
    var sortOrder = [KeyPathComparator(\Connection.name, comparator: .localizedStandard)]

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private static let log = RDPLogging.logger("Library")

    init(store: ConnectionStore) {
        self.store = store
    }

    /// The app's library. Tests make their own.
    static let shared = standard()

    /// Vistara's library in Application Support.
    static func standard() -> LibraryModel {
        let directory = (try? ConnectionStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(VistaraCore.applicationSupportFolderName)
        return LibraryModel(store: ConnectionStore(directory: directory))
    }

    func load() async {
        do {
            let result = try await store.load()
            library = result.library
            corruptFileBackup = result.corruptFileBackup
            skippedEntries = result.skippedEntries
            originalFileCopy = result.originalFileCopy
            identifiersInKeptCopies = await store.identifiersInKeptCopies()
            showsSkippedNotice = !result.skippedEntries.isEmpty
            loadState = .loaded
            if !pendingImports.isEmpty {
                let urls = pendingImports
                pendingImports = []
                await importRDPFiles(urls)
            }
        } catch LibraryCodec.CodecError.newerSchema {
            loadState = .unreadable(
                "Your connections were saved by a newer version of Vistara. Update Vistara to use them."
            )
        } catch {
            Self.log.error("Loading the library failed: \(String(describing: error), privacy: .public)")
            loadState = .unreadable("Vistara can’t read your connections. Check that your disk is available.")
        }
    }

    var canChange: Bool { loadState == .loaded }

    // MARK: Changes

    func connection(_ id: Connection.ID) -> Connection? {
        library.connections.first { $0.id == id }
    }

    func add(_ connection: Connection) async {
        await save(connection)
    }

    /// Adds the connection, or replaces the one with the same identifier.
    func save(_ connection: Connection) async {
        guard canChange else { return }
        if let index = library.connections.firstIndex(where: { $0.id == connection.id }) {
            library.connections[index] = connection
        } else {
            library.connections.append(connection)
        }
        await save()
    }

    /// Copies the connections, each after its original, and returns the
    /// copies' identifiers. A copy is never used yet and has its own Keychain
    /// item, so it asks for a password the first time.
    @discardableResult
    func duplicate(_ ids: Set<Connection.ID>) async -> [Connection.ID] {
        guard canChange else { return [] }
        var copies: [Connection.ID] = []
        for original in library.connections where ids.contains(original.id) {
            var copy = original
            copy.id = UUID()
            copy.name = copyName(for: original.name.isEmpty ? original.host : original.name)
            copy.lastConnectedAt = nil
            copy.isFavorite = false
            guard let index = library.connections.firstIndex(where: { $0.id == original.id }) else { continue }
            library.connections.insert(copy, at: index + 1)
            copies.append(copy.id)
        }
        await save()
        return copies
    }

    /// "Build Server Copy", then "Build Server Copy 2", as Finder does.
    private func copyName(for name: String) -> String {
        let names = Set(library.connections.map(\.name))
        var candidate = "\(name) Copy"
        var number = 2
        while names.contains(candidate) {
            candidate = "\(name) Copy \(number)"
            number += 1
        }
        return candidate
    }

    /// Deletes without asking; Undo restores. The connections' Keychain items
    /// stay until the deletion can no longer be undone: see
    /// `removeOrphanedCredentials(from:)`.
    ///
    /// Synchronous, so that when Redo calls it from an undo handler the undo
    /// manager records its registration as the matching Undo.
    func delete(_ ids: Set<Connection.ID>, undoManager: UndoManager?) {
        guard canChange else { return }
        let removed = library.connections.enumerated().filter { ids.contains($0.element.id) }
            .map { RemovedConnection(index: $0.offset, connection: $0.element) }
        guard !removed.isEmpty else { return }
        library.connections.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        scheduleSave()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(removed, undoManager: undoManager) }
        }
        undoManager?.setActionName(removed.count == 1 ? "Delete Connection" : "Delete Connections")
    }

    struct RemovedConnection: Sendable {
        var index: Int
        var connection: Connection
    }

    /// Puts deleted connections back where they were. Called by Undo.
    private func restore(_ removed: [RemovedConnection], undoManager: UndoManager?) {
        guard canChange else { return }
        for item in removed.sorted(by: { $0.index < $1.index }) {
            library.connections.insert(item.connection, at: min(item.index, library.connections.count))
        }
        let ids = Set(removed.map(\.connection.id))
        selectedIDs = ids
        scheduleSave()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.delete(ids, undoManager: undoManager) }
        }
        undoManager?.setActionName(removed.count == 1 ? "Delete Connection" : "Delete Connections")
    }

    /// Removes the Keychain items of connections that are no longer in the
    /// library. Called at launch and at quit, when no Undo can bring a
    /// deleted connection back. Never runs while the library is unreadable
    /// or unsaved, so a missing connection always really is gone.
    func removeOrphanedCredentials(from store: any CredentialStore) {
        guard loadState == .loaded, !saveFailed, let keys = try? store.keys() else { return }
        // An entry that could not be read may still own a password. Keep the
        // ones whose identifier is known; without one, keep everything.
        let skipped = skippedEntries.filter { $0.kind == .connection }
        guard skipped.allSatisfy({ $0.id != nil }) else { return }
        // A copy of the file kept next to it holds its connections too.
        let kept = Set(library.connections.map(\.id.uuidString))
            .union(skipped.compactMap { $0.id?.uppercased() })
            .union(identifiersInKeptCopies)
        for key in keys where !kept.contains(key.uppercased()) {
            try? store.remove(for: key)
        }
    }

    /// Notes that a connection was just used.
    func recordConnection(_ id: Connection.ID, at date: Date = Date()) async {
        guard canChange, let index = library.connections.firstIndex(where: { $0.id == id }) else { return }
        library.connections[index].lastConnectedAt = date
        await save()
    }

    /// Writes the library as it is now, after any write still in progress,
    /// so writes land in the order the changes were made.
    func scheduleSave() {
        let previous = pendingSave
        let snapshot = library
        let store = store
        pendingSave = Task { [weak self] in
            await previous?.value
            do {
                try await store.save(snapshot)
                self?.saveFailed = false
            } catch {
                Self.log.error("Saving the library failed: \(String(describing: error), privacy: .public)")
                self?.saveFailed = true
            }
        }
    }

    private func save() async {
        scheduleSave()
        await flushSaves()
    }

    /// Waits until every change so far is written.
    func flushSaves() async {
        await pendingSave?.value
    }

    // MARK: Sidebar

    var folders: [Folder] {
        library.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every tag in use, each once, regardless of case.
    var tags: [String] {
        var seen: [String: String] = [:]
        for tag in library.connections.flatMap(\.tags) {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            seen[trimmed.lowercased()] = seen[trimmed.lowercased()] ?? trimmed
        }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func title(for item: SidebarItem) -> String {
        switch item {
        case .all: "All Connections"
        case .favorites: "Favorites"
        case .recents: "Recents"
        case .folder(let id): library.folders.first { $0.id == id }?.name ?? "Folder"
        case .tag(let tag): tag
        }
    }

    // MARK: List

    /// The connections the sidebar selects and the search matches, sorted.
    var visibleConnections: [Connection] {
        var connections = library.connections
        if selection == .recents {
            connections = Array(
                connections.filter { $0.lastConnectedAt != nil }.sorted(using: Self.lastUsedFirst)
                    .prefix(Self.recentsLimit)
            )
        }
        return connections
            .filter { Self.belongs($0, to: selection) && Self.matches($0, search: searchText) }
            .sorted(using: sortOrder)
    }

    static func belongs(_ connection: Connection, to item: SidebarItem) -> Bool {
        switch item {
        case .all: true
        case .favorites: connection.isFavorite
        case .recents: connection.lastConnectedAt != nil
        case .folder(let id): connection.folderID == id
        case .tag(let tag): connection.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    /// Matches name, host, user name, and tags, ignoring case and accents.
    static func matches(_ connection: Connection, search: String) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [connection.name, connection.host, connection.username] + connection.tags
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

extension Connection {
    /// For sorting by Last Used: never used sorts as the oldest.
    var lastUsedSortKey: Date { lastConnectedAt ?? .distantPast }
}

extension SessionTarget {
    /// What a session window needs from a saved connection.
    init(connection: Connection) {
        self.init(
            name: connection.name.isEmpty ? connection.host : connection.name,
            host: connection.host,
            port: UInt16(clamping: connection.port),
            username: connection.username,
            domain: connection.domain.isEmpty ? nil : connection.domain
        )
        connectionID = connection.id
        resolutionMode = connection.resolutionMode
        fixedWidth = connection.fixedWidth
        fixedHeight = connection.fixedHeight
        usesHiDPI = connection.usesHiDPI
        requiresNLA = connection.requiresNLA
        certificatePolicy = connection.certificatePolicy
        audioMode = connection.audioMode
        sharesClipboard = connection.sharesClipboard
        reconnectsAutomatically = connection.reconnectsAutomatically
        sharedFolders = connection.sharedFolders
    }
}

extension LibraryModel {
    /// Saves fresh bookmarks of shared folders that moved, so the connection
    /// follows them. A folder the user removed or changed meanwhile is left
    /// as it is.
    func renewSharedFolders(of id: Connection.ID, _ renewals: [SharedFolderAccess.Renewal]) async {
        guard canChange, let index = library.connections.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        for renewal in renewals {
            guard let folder = library.connections[index].sharedFolders.firstIndex(of: renewal.old) else { continue }
            library.connections[index].sharedFolders[folder] = renewal.new
            changed = true
        }
        if changed { await save() }
    }
}
