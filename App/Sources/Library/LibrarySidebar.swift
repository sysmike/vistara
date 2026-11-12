import SwiftUI
import VistaraCore

/// Two levels at most: section headers and their items. Nothing actionable at
/// the bottom. Folders and Tags collapse.
struct LibrarySidebar: View {
    @Bindable var model: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @AppStorage("SidebarShowsFolders") private var showsFolders = true
    @AppStorage("SidebarShowsTags") private var showsTags = true

    var body: some View {
        List(selection: selection) {
            Section {
                row(.all, systemImage: "rectangle.stack")
                row(.favorites, systemImage: "star")
                    .dropDestination(for: ConnectionReference.self) { items, _ in
                        let ids = Set(items.map(\.id))
                        if model.wouldFavorite(ids) { model.toggleFavorite(ids) }
                        return true
                    }
                row(.recents, systemImage: "clock")
            }
            if !model.folders.isEmpty {
                Section("Folders", isExpanded: $showsFolders) {
                    ForEach(model.folders) { folder in
                        folderRow(folder)
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Tags", isExpanded: $showsTags) {
                    ForEach(model.tags, id: \.self) { tag in
                        row(.tag(tag), systemImage: "tag")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Folder") { model.addFolder() }
                .disabled(!model.canChange)
        }
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

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        Group {
            if model.renamingFolderID == folder.id {
                FolderNameField(name: folder.name) { name in
                    model.renameFolder(folder.id, to: name)
                } cancel: {
                    model.renamingFolderID = nil
                }
                .tag(LibraryModel.SidebarItem.folder(folder.id))
            } else {
                row(.folder(folder.id), systemImage: "folder")
            }
        }
        .dropDestination(for: ConnectionReference.self) { items, _ in
            model.move(Set(items.map(\.id)), to: folder.id, undoManager: undoManager)
            return true
        }
        .contextMenu {
            Button("Rename Folder") { model.renamingFolderID = folder.id }
            Button("Delete Folder") { model.deleteFolder(folder.id, undoManager: undoManager) }
            // Said before, instead of asked after: deleting is undoable.
            let count = model.count(in: folder.id)
            if count > 0 {
                Text(count == 1
                    ? "Its connection stays in All Connections."
                    : "Its \(count) connections stay in All Connections.")
            }
        }
    }
}

/// Edits a folder's name in place, as Finder does.
private struct FolderNameField: View {
    @State var name: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Label {
            TextField("Folder Name", text: $name)
                .labelsHidden()
                .focused($isFocused)
                .onSubmit { commit(name) }
                .onExitCommand(perform: cancel)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit(name) }
                }
        } icon: {
            SidebarIcon(systemImage: "folder")
        }
        .onAppear { isFocused = true }
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
