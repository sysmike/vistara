import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VistaraCore

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
                    Table(of: Connection.self, selection: $model.selectedIDs, sortOrder: $model.sortOrder) {
                        nameColumn(ideal: (width - 170) * 0.45)
                        hostColumn(ideal: (width - 170) * 0.55)
                        lastUsedColumn
                    } rows: {
                        draggableRows(rows)
                    }
                } else if width >= 300 {
                    Table(of: Connection.self, selection: $model.selectedIDs, sortOrder: $model.sortOrder) {
                        nameColumn(ideal: (width - 50) * 0.45)
                        hostColumn(ideal: (width - 50) * 0.55)
                    } rows: {
                        draggableRows(rows)
                    }
                } else {
                    Table(of: Connection.self, selection: $model.selectedIDs, sortOrder: $model.sortOrder) {
                        nameColumn(ideal: width - 40)
                    } rows: {
                        draggableRows(rows)
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
    /// Rows that can be dragged onto a folder or Favorites in the sidebar.
    private func draggableRows(_ rows: [Connection]) -> some TableRowContent<Connection> {
        ForEach(rows) { connection in
            TableRow(connection)
                .draggable(ConnectionReference(connection))
        }
    }

    private func nameColumn(ideal: CGFloat) -> some TableColumnContent<Connection, KeyPathComparator<Connection>> {
        TableColumn("Name", value: \Connection.name, comparator: .localizedStandard) { connection in
            HStack(spacing: 4) {
                Label(SessionTarget(connection: connection).name, systemImage: "desktopcomputer")
                if connection.isFavorite {
                    // A shape, not a colour, says favorite.
                    Image(systemName: "star.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .accessibilityLabel("Favorite")
                }
            }
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
            Button(model.wouldFavorite(ids) ? "Add to Favorites" : "Remove from Favorites") {
                model.toggleFavorite(ids)
            }
            .disabled(!commands.canChange)
            let current = ConnectionsView.commonFolder(of: ids, in: model.library)
            MoveToFolderMenu(folders: model.folders, current: current) { folderID in
                commands.move(ids, folderID)
            }
            .disabled(!commands.canChange)
            Divider()
            Button(ids.count == 1 ? "Delete Connection" : "Delete Connections") { commands.delete(ids) }
                .disabled(!commands.canChange)
        }
    }
}

/// Move to Folder, with a check mark at the folder the connections are in.
/// The keyboard's way to do what dragging onto a folder does.
struct MoveToFolderMenu: View {
    let folders: [Folder]
    /// The folder they share: nil for none shared, .some(nil) for no folder.
    let current: Folder.ID??
    let move: (Folder.ID?) -> Void

    var body: some View {
        Menu("Move to Folder") {
            Toggle("None", isOn: binding(for: nil))
            if !folders.isEmpty { Divider() }
            ForEach(folders) { folder in
                Toggle(folder.name, isOn: binding(for: folder.id))
            }
        }
        .disabled(folders.isEmpty)
    }

    private func binding(for folderID: Folder.ID?) -> Binding<Bool> {
        Binding(get: { current == .some(folderID) }, set: { _ in move(folderID) })
    }
}

/// A connection being dragged: inside Vistara it names the connection, in
/// other apps it is the computer's address as text.
struct ConnectionReference: Codable, Transferable {
    var id: UUID
    var address: String

    init(_ connection: Connection) {
        id = connection.id
        address = ConnectionTable.address(of: connection)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vistaraConnection)
        ProxyRepresentation(exporting: \.address)
    }
}

extension UTType {
    /// Declared in App/Info.plist.
    static let vistaraConnection = UTType(exportedAs: "io.github.sysmike.vistara.connection")
}
