import AppKit
import SwiftUI
import VistaraCore

/// The primary window: a sidebar of sections and a table of connections.
struct ConnectionsView: View {
    @Bindable var model: LibraryModel
    let connect: (Connection) -> Void

    @State private var isAddingConnection = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            ConnectionTable(model: model, connect: connect, addConnection: { isAddingConnection = true })
                .navigationTitle(model.title(for: model.selection))
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Connection", systemImage: "plus") { isAddingConnection = true }
                    .help("New Connection")
                    .disabled(!model.canChange)
            }
        }
        .sheet(isPresented: $isAddingConnection) {
            NewConnectionSheet { connection in
                Task { await model.add(connection) }
            }
        }
        .focusedSceneValue(\.libraryActions, LibraryActions(
            newConnection: model.canChange ? { isAddingConnection = true } : nil,
            find: ConnectionsView.focusSearchField
        ))
        .frame(minWidth: 560, minHeight: 320)
    }

    /// Puts the keyboard in the toolbar's search field. SwiftUI offers no way
    /// to focus a searchable field before macOS 15.
    static func focusSearchField() {
        let items = NSApp.keyWindow?.toolbar?.items ?? []
        items.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
    }
}

/// Commands the menu bar sends to the connections window in front.
struct LibraryActions {
    var newConnection: (() -> Void)?
    var find: () -> Void
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
    let connect: (Connection) -> Void
    let addConnection: () -> Void

    @State private var selection = Set<Connection.ID>()

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
            Button("New Connection", action: addConnection)
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

    /// A narrow window drops Last Used first, then Host.
    private func table(_ rows: [Connection]) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            table(rows, showsHost: width >= 300, showsLastUsed: width >= 460)
        }
    }

    private func table(_ rows: [Connection], showsHost: Bool, showsLastUsed: Bool) -> some View {
        Table(rows, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \Connection.name, comparator: .localizedStandard) { connection in
                Label(SessionTarget(connection: connection).name, systemImage: "desktopcomputer")
            }
            .width(min: 120, ideal: 200)
            if showsHost {
                TableColumn("Host", value: \Connection.host, comparator: .localizedStandard) { connection in
                    Text(Self.address(of: connection))
                }
                .width(min: 120, ideal: 220)
            }
            if showsLastUsed {
                TableColumn("Last Used", value: \Connection.lastUsedSortKey) { connection in
                    Text(LastUsedFormat.string(for: connection.lastConnectedAt))
                }
                .width(min: 80, ideal: 100, max: 140)
            }
        }
        .contextMenu(forSelectionType: Connection.ID.self) { ids in
            Button("Connect") { open(ids) }
                .disabled(ids.isEmpty)
        } primaryAction: { ids in
            open(ids)
        }
    }

    static func address(of connection: Connection) -> String {
        connection.port == Connection.defaultPort ? connection.host : "\(connection.host):\(connection.port)"
    }

    private func open(_ ids: Set<Connection.ID>) {
        for connection in model.library.connections where ids.contains(connection.id) {
            connect(connection)
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
