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
    /// Set when the last change could not be saved; set by LibraryModel+Sync.
    var saveFailed = false

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

    // Where the library is kept (docs/DESIGN.md, Connections on several
    // Macs); set by this type and LibraryModel+Sync only.
    /// The folder chosen in Settings > Sync, or nil for On This Mac.
    var syncFolder: SyncFolderChoice?
    /// How the folder was at the last sync; nil while on this Mac.
    var syncState: SyncedLibraryStore.FolderState?
    @ObservationIgnored var storage: LibraryStorage
    /// This Mac's library file's folder, which holds its copy in either place.
    @ObservationIgnored let directory: URL
    /// Where the choice of folder is kept; tests keep none.
    @ObservationIgnored let choiceDefaults: UserDefaults?
    /// The library as the folder's store has it, as far as this model knows:
    /// what the next save's changes are made to.
    @ObservationIgnored var syncedBase = Library()
    /// Files in the folder that could not be read, which may hold connections.
    @ObservationIgnored var damagedSyncFiles: [String] = []
    /// The folder opened through its bookmark, closed when no longer used.
    @ObservationIgnored var openedFolder: URL?
    @ObservationIgnored var folderWatch: Task<Void, Never>?
    @ObservationIgnored var isCheckingFolder = false
    /// Writes and syncs run one after another; see LibraryModel+Sync.
    @ObservationIgnored var pendingSave: Task<Void, Never>?
    @ObservationIgnored var lastOperation = 0
    static let log = RDPLogging.logger("Library")

    init(store: ConnectionStore, choiceDefaults: UserDefaults? = nil) {
        storage = .thisMac(store)
        directory = store.directory
        self.choiceDefaults = choiceDefaults
    }

    /// The app's library. Tests make their own.
    static let shared = standard()

    /// Vistara's library in Application Support, in the folder chosen in
    /// Settings > Sync if there is one.
    static func standard() -> LibraryModel {
        let directory = (try? ConnectionStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(VistaraCore.applicationSupportFolderName)
        let model = LibraryModel(store: ConnectionStore(directory: directory), choiceDefaults: .standard)
        if let choice = SyncFolderChoice.saved(in: .standard) { model.useFolder(choice) }
        return model
    }

    func load() async {
        do {
            let result: ConnectionStore.LoadResult
            switch storage {
            case .thisMac(let store):
                result = try await store.load()
                identifiersInKeptCopies = await store.identifiersInKeptCopies()
            case .folder(let store):
                result = try await store.load()
                identifiersInKeptCopies = await store.identifiersInKeptCopies()
            }
            library = result.library
            syncedBase = result.library
            corruptFileBackup = result.corruptFileBackup
            skippedEntries = result.skippedEntries
            originalFileCopy = result.originalFileCopy
            showsSkippedNotice = !result.skippedEntries.isEmpty
            loadState = .loaded
            startSyncing()
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

    /// Notes that a connection was just used.
    func recordConnection(_ id: Connection.ID, at date: Date = Date()) async {
        guard canChange, let index = library.connections.firstIndex(where: { $0.id == id }) else { return }
        library.connections[index].lastConnectedAt = date
        await save()
    }

    /// Writes the library as it is now and waits until it is written.
    func save() async {
        scheduleSave()
        await flushSaves()
    }
}

extension LibraryModel {
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
