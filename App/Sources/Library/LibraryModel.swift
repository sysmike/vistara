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

    private(set) var library = Library()
    private(set) var loadState = LoadState.loading
    /// Where an unreadable file was moved before starting a new library.
    private(set) var corruptFileBackup: URL?
    /// Set when the last change could not be saved.
    private(set) var saveFailed = false

    var selection = SidebarItem.all
    var searchText = ""
    var sortOrder = [KeyPathComparator(\Connection.name, comparator: .localizedStandard)]

    @ObservationIgnored private let store: ConnectionStore
    private static let log = RDPLogging.logger("Library")

    init(store: ConnectionStore) {
        self.store = store
    }

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
            loadState = .loaded
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

    func add(_ connection: Connection) async {
        guard canChange else { return }
        library.connections.append(connection)
        await save()
    }

    /// Notes that a connection was just used.
    func recordConnection(_ id: Connection.ID, at date: Date = Date()) async {
        guard canChange, let index = library.connections.firstIndex(where: { $0.id == id }) else { return }
        library.connections[index].lastConnectedAt = date
        await save()
    }

    private func save() async {
        do {
            try await store.save(library)
            saveFailed = false
        } catch {
            Self.log.error("Saving the library failed: \(String(describing: error), privacy: .public)")
            saveFailed = true
        }
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
        library.connections
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
    }
}
