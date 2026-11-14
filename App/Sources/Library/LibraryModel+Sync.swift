import Foundation
import VistaraCore

/// Where the library is kept (docs/DESIGN.md, Connections on several Macs).
enum LibraryStorage {
    /// Only on this Mac, in its library file.
    case thisMac(ConnectionStore)
    /// In a folder several Macs share, with this Mac's library file as its
    /// copy.
    case folder(SyncedLibraryStore)
}

/// Writes, syncs, and the choice of where the library is kept.
extension LibraryModel {
    /// How often the folder is looked at for other Macs' changes. Looking
    /// only lists it; it is read when something changed.
    static let folderCheckInterval = Duration.seconds(2)

    // MARK: Writes and syncs

    /// Writes the library as it is now, after any write still in progress,
    /// so writes land in the order the changes were made.
    func scheduleSave() {
        let snapshot = library
        // The changes are those made to what the store was last given.
        let base = syncedBase
        syncedBase = snapshot
        switch storage {
        case .thisMac(let store):
            enqueue {
                try await store.save(snapshot)
                return nil
            }
        case .folder(let store):
            enqueue { try await store.save(snapshot, basedOn: base) }
        }
    }

    /// Waits until every change so far is written, and every sync so far done.
    func flushSaves() async {
        await pendingSave?.value
    }

    /// Takes other Macs' changes now, and waits for them.
    func syncNow() async {
        guard case .folder(let store) = storage, canChange else { return }
        enqueue { try await store.sync() }
        await flushSaves()
    }

    /// Runs one write or sync after those before it.
    private func enqueue(_ operation: @escaping @Sendable () async throws -> SyncedLibraryStore.SyncResult?) {
        lastOperation += 1
        let generation = lastOperation
        let previous = pendingSave
        pendingSave = Task { [weak self] in
            await previous?.value
            do {
                let result = try await operation()
                self?.saveFailed = false
                if let result { self?.received(result, generation: generation) }
            } catch {
                Self.log.error("Saving the library failed: \(String(describing: error), privacy: .public)")
                self?.saveFailed = true
            }
        }
    }

    /// Shows what the folder's store has now, with other Macs' changes. A
    /// change made here since is still to be written, and its result follows:
    /// showing this one would take that change away for a moment.
    private func received(_ result: SyncedLibraryStore.SyncResult, generation: Int) {
        guard case .folder = storage else { return }
        syncState = result.folder
        damagedSyncFiles = result.damagedFiles
        guard generation == lastOperation else { return }
        syncedBase = result.library
        guard library != result.library else { return }
        library = result.library
        selectedIDs.formIntersection(library.connections.map(\.id))
    }

    // MARK: Choosing where

    /// Keeps the library in the folder from now on. This Mac's connections
    /// are added to what is there, and nothing is deleted.
    func keepInFolder(_ url: URL) async throws {
        guard canChange else { return }
        let choice = try SyncFolderChoice(for: url)
        await flushSaves()
        let store = useFolder(choice)
        if let choiceDefaults { choice.save(in: choiceDefaults) }
        enqueue {
            _ = try await store.load()
            return try await store.join()
        }
        startWatching()
        await flushSaves()
    }

    /// Keeps the library on this Mac only, as it is now. The folder is left
    /// as it is.
    func keepOnThisMac() async {
        guard syncFolder != nil else { return }
        await flushSaves()
        closeFolder()
        storage = .thisMac(ConnectionStore(directory: directory))
        syncFolder = nil
        syncState = nil
        damagedSyncFiles = []
        if let choiceDefaults { SyncFolderChoice.forget(in: choiceDefaults) }
    }

    /// Opens the chosen folder and keeps the library there. A folder that
    /// can't be opened now is the path it was chosen at, unreachable until
    /// it is back.
    @discardableResult
    func useFolder(_ choice: SyncFolderChoice) -> SyncedLibraryStore {
        closeFolder()
        var choice = choice
        var url = URL(fileURLWithPath: choice.path, isDirectory: true)
        if let opened = choice.open() {
            openedFolder = opened.url
            url = opened.url
            if let moved = opened.moved {
                choice = moved
                if let choiceDefaults { moved.save(in: choiceDefaults) }
            }
        }
        let store = SyncedLibraryStore(localDirectory: directory, folder: url)
        storage = .folder(store)
        syncFolder = choice
        return store
    }

    private func closeFolder() {
        folderWatch?.cancel()
        folderWatch = nil
        openedFolder?.stopAccessingSecurityScopedResource()
        openedFolder = nil
    }

    // MARK: Watching the folder

    /// Syncs once the library is loaded, then whenever the folder changes.
    func startSyncing() {
        guard case .folder(let store) = storage, canChange else { return }
        enqueue { try await store.sync() }
        startWatching()
    }

    private func startWatching() {
        guard folderWatch == nil else { return }
        folderWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.folderCheckInterval)
                // Gone with the model, as in tests.
                guard let self else { return }
                await self.checkFolder()
            }
        }
    }

    /// Syncs if the folder changed, or wasn't there last time.
    func checkFolder() async {
        guard !isCheckingFolder, canChange, let choice = syncFolder else { return }
        isCheckingFolder = true
        defer { isCheckingFolder = false }
        if syncState == .unreachable { reopenFolder(choice) }
        guard case .folder(let store) = storage, await store.needsSync() else { return }
        await syncNow()
    }

    /// Opens the folder again if its bookmark couldn't be opened before, or
    /// it moved, as when it was renamed.
    private func reopenFolder(_ choice: SyncFolderChoice) {
        guard let opened = choice.open() else { return }
        guard openedFolder == nil || opened.moved != nil else {
            // Still where it was, and open already: it is away, not moved.
            opened.url.stopAccessingSecurityScopedResource()
            return
        }
        openedFolder?.stopAccessingSecurityScopedResource()
        openedFolder = opened.url
        if let moved = opened.moved {
            syncFolder = moved
            if let choiceDefaults { moved.save(in: choiceDefaults) }
        }
        let store = SyncedLibraryStore(localDirectory: directory, folder: opened.url)
        storage = .folder(store)
        enqueue {
            _ = try await store.load()
            return try await store.sync()
        }
    }
}
