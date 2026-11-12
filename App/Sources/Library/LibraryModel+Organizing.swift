import Foundation
import VistaraCore

/// Favorites, folders, and tags.
extension LibraryModel {
    /// Marks all as favorites, or, when all already are, none.
    func toggleFavorite(_ ids: Set<Connection.ID>) {
        guard canChange else { return }
        let chosen = library.connections.filter { ids.contains($0.id) }
        let favorite = !chosen.allSatisfy(\.isFavorite)
        for index in library.connections.indices where ids.contains(library.connections[index].id) {
            library.connections[index].isFavorite = favorite
        }
        scheduleSave()
    }

    /// Whether the connections would become favorites on `toggleFavorite`.
    func wouldFavorite(_ ids: Set<Connection.ID>) -> Bool {
        !library.connections.filter { ids.contains($0.id) }.allSatisfy(\.isFavorite)
    }

    /// Adds a folder named "New Folder" (or "New Folder 2"…) and starts
    /// renaming it in the sidebar.
    @discardableResult
    func addFolder() -> Folder.ID? {
        guard canChange else { return nil }
        let names = Set(library.folders.map(\.name))
        var name = "New Folder"
        var number = 2
        while names.contains(name) {
            name = "New Folder \(number)"
            number += 1
        }
        let folder = Folder(name: name)
        library.folders.append(folder)
        scheduleSave()
        selection = .folder(folder.id)
        renamingFolderID = folder.id
        return folder.id
    }

    /// Renames a folder. An empty name keeps the old one.
    func renameFolder(_ id: Folder.ID, to name: String) {
        renamingFolderID = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChange, !trimmed.isEmpty, let index = library.folders.firstIndex(where: { $0.id == id }) else {
            return
        }
        library.folders[index].name = trimmed
        scheduleSave()
    }

    /// The number of connections in a folder.
    func count(in folderID: Folder.ID) -> Int {
        library.connections.filter { $0.folderID == folderID }.count
    }

    /// Deletes a folder without asking. Its connections stay in the library,
    /// outside any folder; Undo puts the folder and its connections back.
    func deleteFolder(_ id: Folder.ID, undoManager: UndoManager?) {
        guard canChange, let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
        let folder = library.folders.remove(at: index)
        let members = Set(library.connections.filter { $0.folderID == id }.map(\.id))
        for member in library.connections.indices where members.contains(library.connections[member].id) {
            library.connections[member].folderID = nil
        }
        if selection == .folder(id) { selection = .all }
        scheduleSave()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreFolder(folder, at: index, members: members, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Delete Folder")
    }

    private func restoreFolder(
        _ folder: Folder, at index: Int, members: Set<Connection.ID>, undoManager: UndoManager?
    ) {
        guard canChange else { return }
        library.folders.insert(folder, at: min(index, library.folders.count))
        for member in library.connections.indices where members.contains(library.connections[member].id) {
            library.connections[member].folderID = folder.id
        }
        selection = .folder(folder.id)
        scheduleSave()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.deleteFolder(folder.id, undoManager: undoManager) }
        }
        undoManager?.setActionName("Delete Folder")
    }

    /// Moves connections into a folder, or out of any with nil. Undoable,
    /// because a drag can land in the wrong place.
    func move(_ ids: Set<Connection.ID>, to folderID: Folder.ID?, undoManager: UndoManager?) {
        guard canChange, folderID == nil || library.folders.contains(where: { $0.id == folderID }) else { return }
        var previous: [Connection.ID: Folder.ID?] = [:]
        for index in library.connections.indices where ids.contains(library.connections[index].id) {
            let connection = library.connections[index]
            guard connection.folderID != folderID else { continue }
            previous[connection.id] = connection.folderID
            library.connections[index].folderID = folderID
        }
        guard !previous.isEmpty else { return }
        scheduleSave()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.putBack(previous, folderID: folderID, undoManager: undoManager) }
        }
        undoManager?.setActionName("Move to Folder")
    }

    private func putBack(_ previous: [Connection.ID: Folder.ID?], folderID: Folder.ID?, undoManager: UndoManager?) {
        for index in library.connections.indices {
            if let folder = previous[library.connections[index].id] { library.connections[index].folderID = folder }
        }
        scheduleSave()
        let ids = Set(previous.keys)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.move(ids, to: folderID, undoManager: undoManager) }
        }
        undoManager?.setActionName("Move to Folder")
    }

    /// Adds a tag to connections, keeping the spelling of a tag already in use.
    func addTag(_ tag: String, to ids: Set<Connection.ID>) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChange, !trimmed.isEmpty else { return }
        let spelling = tags.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
        for index in library.connections.indices where ids.contains(library.connections[index].id) {
            let has = library.connections[index].tags.contains { $0.caseInsensitiveCompare(spelling) == .orderedSame }
            if !has { library.connections[index].tags.append(spelling) }
        }
        scheduleSave()
    }
}
