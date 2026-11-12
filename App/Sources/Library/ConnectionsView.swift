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
            ConnectionEditor(draft: draft(for: request), folders: model.folders) { connection in
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
            delete: { ids in
                Task { await model.delete(ids, undoManager: undoManager) }
            },
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
            delete: canChange ? { commands.delete(ids) } : nil
        )
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

/// Two levels at most: section headers and their items. Nothing actionable at
/// the bottom.
struct LibrarySidebar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: selection) {
            Section {
                row(.all, systemImage: "rectangle.stack")
                row(.favorites, systemImage: "star")
                row(.recents, systemImage: "clock")
            }
            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders) { folder in
                        row(.folder(folder.id), systemImage: "folder")
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.self) { tag in
                        row(.tag(tag), systemImage: "tag")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<LibraryModel.SidebarItem?> {
        Binding(get: { model.selection }, set: { model.selection = $0 ?? .all })
    }

    private func row(_ item: LibraryModel.SidebarItem, systemImage: String) -> some View {
        Label {
            Text(model.title(for: item))
        } icon: {
            SidebarIcon(systemImage: systemImage)
        }
        .tag(item)
    }
}

/// A sidebar symbol in the accent color, and in the selection's own color
/// on the selected row (HIG Sidebars).
private struct SidebarIcon: View {
    let systemImage: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if prominence == .increased {
            Image(systemName: systemImage)
        } else {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}

/// The connections in the selected section, or what to do when there are none.
struct ConnectionTable: View {
    @Bindable var model: LibraryModel
    let commands: ConnectionCommands

    var body: some View {
        let rows = model.visibleConnections
        Group {
            if case .unreadable(let reason) = model.loadState {
                ContentUnavailableView("Connections Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
            } else if model.loadState == .loading {
                ProgressView()
            } else if model.library.connections.isEmpty {
                emptyLibrary
            } else if rows.isEmpty {
                emptySelection
            } else {
                table(rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Connections", systemImage: "desktopcomputer")
        } description: {
            if let backup = model.corruptFileBackup {
                Text("Vistara couldn’t read your connections and started a new list. "
                    + "The old file was kept as “\(backup.lastPathComponent)”.")
            } else {
                Text("Add the computers you connect to, and they’ll appear here.")
            }
        } actions: {
            Button("New Connection", action: commands.new)
                .disabled(!commands.canChange)
        }
    }

    @ViewBuilder private var emptySelection: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            switch model.selection {
            case .favorites:
                ContentUnavailableView("No Favorites", systemImage: "star",
                                       description: Text("Connections you mark as favorites appear here."))
            case .recents:
                ContentUnavailableView("No Recent Connections", systemImage: "clock",
                                       description: Text("Connections you use appear here."))
            default:
                let place = model.title(for: model.selection)
                ContentUnavailableView("No Connections Here", systemImage: "tray",
                                       description: Text("Connections you add to “\(place)” appear here."))
            }
        }
    }

    /// A narrow window drops Last Used first, then Host. Three tables rather
    /// than conditional columns, which need macOS 14.4.
    private func table(_ rows: [Connection]) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Group {
                if width >= 460 {
                    Table(rows, selection: $model.selectedIDs, sortOrder: $model.sortOrder) {
                        nameColumn(ideal: (width - 170) * 0.45)
                        hostColumn(ideal: (width - 170) * 0.55)
                        lastUsedColumn
                    }
                } else if width >= 300 {
                    Table(rows, selection: $model.selectedIDs, sortOrder: $model.sortOrder) {
                        nameColumn(ideal: (width - 50) * 0.45)
                        hostColumn(ideal: (width - 50) * 0.55)
                    }
                } else {
                    Table(rows, selection: $model.selectedIDs, sortOrder: $model.sortOrder) {
                        nameColumn(ideal: width - 40)
                    }
                }
            }
            .contextMenu(forSelectionType: Connection.ID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                commands.connect(ids)
            }
        }
    }

    // Ideal widths that add up to the space there is, so nothing starts out
    // scrolled or cut off.
    private func nameColumn(ideal: CGFloat) -> some TableColumnContent<Connection, KeyPathComparator<Connection>> {
        TableColumn("Name", value: \Connection.name, comparator: .localizedStandard) { connection in
            Label(SessionTarget(connection: connection).name, systemImage: "desktopcomputer")
        }
        .width(min: 100, ideal: max(100, ideal))
    }

    private func hostColumn(ideal: CGFloat) -> some TableColumnContent<Connection, KeyPathComparator<Connection>> {
        TableColumn("Host", value: \Connection.host, comparator: .localizedStandard) { connection in
            Text(Self.address(of: connection))
        }
        .width(min: 100, ideal: max(100, ideal))
    }

    private var lastUsedColumn: some TableColumnContent<Connection, KeyPathComparator<Connection>> {
        TableColumn("Last Used", value: \Connection.lastUsedSortKey) { connection in
            Text(LastUsedFormat.string(for: connection.lastConnectedAt))
        }
        .width(min: 80, ideal: 100, max: 120)
    }

    static func address(of connection: Connection) -> String {
        connection.port == Connection.defaultPort ? connection.host : "\(connection.host):\(connection.port)"
    }

    /// The same commands as the menu bar, for the rows clicked.
    @ViewBuilder
    private func contextMenu(for ids: Set<Connection.ID>) -> some View {
        if ids.isEmpty {
            Button("New Connection…", action: commands.new)
                .disabled(!commands.canChange)
        } else {
            Button("Connect") { commands.connect(ids) }
            Divider()
            Button("Edit Connection…") { if let id = ids.first { commands.edit(id) } }
                .disabled(ids.count != 1 || !commands.canChange)
            Button("Duplicate") { commands.duplicate(ids) }
                .disabled(!commands.canChange)
            Divider()
            Button(ids.count == 1 ? "Delete Connection" : "Delete Connections") { commands.delete(ids) }
                .disabled(!commands.canChange)
        }
    }
    }
}

/// "Today", "Yesterday", or a date, as the design asks for lists.
enum LastUsedFormat {
    static func string(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Never" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
