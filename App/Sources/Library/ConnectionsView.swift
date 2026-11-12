import AppKit
import SwiftUI
import VistaraCore

/// The primary window: a sidebar of sections and a table of connections.
struct ConnectionsView: View {
    @Bindable var model: LibraryModel
    let connect: (Connection) -> Void
    /// Called after a connection was saved from the editor.
    var saved: (Connection) -> Void = { _ in }

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            ConnectionTable(model: model, commands: commands)
                .navigationTitle(model.title(for: model.selection))
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Connection", systemImage: "plus") { model.editorRequest = .new }
                    .help("New Connection")
                    .disabled(!model.canChange)
            }
        }
        .sheet(item: $model.editorRequest) { request in
            ConnectionEditor(draft: draft(for: request), folders: model.folders, knownTags: model.tags) { connection in
                Task {
                    await model.save(connection)
                    model.selectedIDs = [connection.id]
                    saved(connection)
                }
            }
        }
        .focusedSceneValue(\.libraryActions, actions)
        .frame(minWidth: 560, minHeight: 320)
    }

    private func draft(for request: LibraryModel.EditorRequest) -> ConnectionDraft {
        switch request {
        case .new: ConnectionDraft()
        case .edit(let id): model.connection(id).map(ConnectionDraft.init) ?? ConnectionDraft()
        }
    }

    /// What the table's context menu and primary action do.
    private var commands: ConnectionCommands {
        ConnectionCommands(
            connect: { ids in
                for connection in model.library.connections where ids.contains(connection.id) { connect(connection) }
            },
            edit: { id in model.editorRequest = .edit(id) },
            duplicate: { ids in
                Task { model.selectedIDs = Set(await model.duplicate(ids)) }
            },
            delete: { ids in model.delete(ids, undoManager: undoManager) },
            move: { ids, folderID in model.move(ids, to: folderID, undoManager: undoManager) },
            new: { model.editorRequest = .new },
            canChange: model.canChange
        )
    }

    /// The menu bar's commands, for the rows selected in the table.
    private var actions: LibraryActions {
        let ids = model.selectedIDs
        let commands = commands
        let canChange = model.canChange && !ids.isEmpty
        return LibraryActions(
            newConnection: model.canChange ? commands.new : nil,
            find: ConnectionsView.focusSearchField,
            connect: ids.isEmpty ? nil : { commands.connect(ids) },
            edit: ids.count == 1 && model.canChange ? { if let id = ids.first { commands.edit(id) } } : nil,
            duplicate: canChange ? { commands.duplicate(ids) } : nil,
            delete: canChange ? { commands.delete(ids) } : nil,
            newFolder: model.canChange ? { model.addFolder() } : nil,
            favorite: canChange ? { model.toggleFavorite(ids) } : nil,
            favoriteTitle: !ids.isEmpty && !model.wouldFavorite(ids) ? "Remove from Favorites" : "Add to Favorites",
            move: canChange ? { folderID in commands.move(ids, folderID) } : nil,
            folders: model.folders,
            currentFolder: Self.commonFolder(of: ids, in: model.library),
            renameFolder: selectedFolder.map { id in { model.renamingFolderID = id } },
            deleteFolder: selectedFolder.map { id in { model.deleteFolder(id, undoManager: undoManager) } }
        )
    }

    /// The folder selected in the sidebar, while the library can change.
    private var selectedFolder: Folder.ID? {
        guard model.canChange, case .folder(let id) = model.selection else { return nil }
        return id
    }

    /// The folder all the connections are in, if they share one: .some(nil)
    /// when none of them is in a folder.
    static func commonFolder(of ids: Set<Connection.ID>, in library: Library) -> Folder.ID?? {
        let folders = Set(library.connections.filter { ids.contains($0.id) }.map(\.folderID))
        return folders.count == 1 ? folders.first : nil
    }

    /// Puts the keyboard in the toolbar's search field. SwiftUI offers no way
    /// to focus a searchable field before macOS 15.
    static func focusSearchField() {
        let items = NSApp.keyWindow?.toolbar?.items ?? []
        items.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
    }
}

/// What can be done with connections in the table.
struct ConnectionCommands {
    var connect: (Set<Connection.ID>) -> Void
    var edit: (Connection.ID) -> Void
    var duplicate: (Set<Connection.ID>) -> Void
    var delete: (Set<Connection.ID>) -> Void
    var move: (Set<Connection.ID>, Folder.ID?) -> Void
    var new: () -> Void
    var canChange: Bool
}

/// Commands the menu bar sends to the connections window in front.
struct LibraryActions {
    var newConnection: (() -> Void)?
    var find: () -> Void
    var connect: (() -> Void)?
    var edit: (() -> Void)?
    var duplicate: (() -> Void)?
    var delete: (() -> Void)?
    var newFolder: (() -> Void)?
    var favorite: (() -> Void)?
    var favoriteTitle = "Add to Favorites"
    var move: ((Folder.ID?) -> Void)?
    var folders: [Folder] = []
    var currentFolder: Folder.ID??
    var renameFolder: (() -> Void)?
    var deleteFolder: (() -> Void)?
}

private struct LibraryActionsKey: FocusedValueKey {
    typealias Value = LibraryActions
}

extension FocusedValues {
    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }
}
