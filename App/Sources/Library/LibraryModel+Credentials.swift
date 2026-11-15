import Foundation
import VistaraCore

extension LibraryModel {
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
        // So does a file in the sync folder that could not be read; its name
        // is its identifier, unless a sync service named a copy of it.
        let damaged = damagedSyncFiles.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        guard damaged.allSatisfy({ UUID(uuidString: $0) != nil }) else { return }
        // A copy of the file kept next to it holds its connections too.
        let keptCopies = identifiersInKeptCopies
        let kept = Set(library.connections.map(\.id.uuidString))
            .union(skipped.compactMap { $0.id?.uppercased() })
            .union(damaged.map { $0.uppercased() })
            .union(keptCopies)
        // A gateway's passwords stay while a connection uses the gateway. What
        // an unreadable entry or a kept copy uses is unknown: keep them all.
        let gateways = library.connections.map(\.gateway).filter(\.isUsed).map(\.credentialKeyPrefix)
        let keepsEveryGateway = !skipped.isEmpty || !keptCopies.isEmpty || !damaged.isEmpty
        for key in keys where !kept.contains(key.uppercased()) {
            if key.hasPrefix(Self.gatewayKeyPrefix),
                keepsEveryGateway || gateways.contains(where: { key.lowercased().hasPrefix($0) }) {
                continue
            }
            try? store.remove(for: key)
        }
    }

    /// What every gateway's Keychain items start with.
    static let gatewayKeyPrefix = "gateway/"
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
