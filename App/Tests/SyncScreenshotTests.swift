import AppKit
import Foundation
import Testing
import VistaraCore
@testable import Vistara

/// Settings > Sync, and the notice above the list, rendered for review.
@Suite(.serialized)
@MainActor
struct SyncScreenshotTests {
    private static let settingsSize = NSSize(width: 520, height: 380)

    /// The sample library kept in a folder "Vistara" in a folder "iCloud Drive".
    private func libraryInAFolder() async throws -> (model: LibraryModel, folder: URL) {
        let (model, directory) = try await temporaryLibrary(SampleLibrary.library)
        let folder = directory.appendingPathComponent("iCloud Drive/Vistara", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await model.keepInFolder(folder)
        return (model, folder)
    }

    @Test(arguments: [false, true])
    func settingsSync(dark: Bool) async throws {
        let (model, _) = try await libraryInAFolder()
        #expect(model.syncState == .reachable)
        let bytes = try await Screenshots.write(
            SyncSettingsView(model: model), size: Self.settingsSize,
            name: dark ? "settings-sync-dark" : "settings-sync", dark: dark
        )
        #expect(bytes > 0)
        await model.keepOnThisMac()
    }

    @Test(arguments: [false, true])
    func settingsSyncUnreachable(dark: Bool) async throws {
        let (model, folder) = try await libraryInAFolder()
        try FileManager.default.removeItem(at: folder)
        await model.syncNow()
        #expect(model.syncState == .unreachable)
        let bytes = try await Screenshots.write(
            SyncSettingsView(model: model), size: Self.settingsSize,
            name: dark ? "settings-sync-unreachable-dark" : "settings-sync-unreachable", dark: dark
        )
        #expect(bytes > 0)
        await model.keepOnThisMac()
    }

    @Test(arguments: [false, true])
    func libraryWithTheFolderAway(dark: Bool) async throws {
        let (model, folder) = try await libraryInAFolder()
        try FileManager.default.removeItem(at: folder)
        await model.syncNow()
        let bytes = try await Screenshots.write(
            ConnectionsView(model: model) { _, _ in }, size: NSSize(width: 780, height: 460),
            name: dark ? "library-sync-unreachable-dark" : "library-sync-unreachable", dark: dark,
            frame: .window(title: "Connections")
        )
        #expect(bytes > 0)
        await model.keepOnThisMac()
    }

    @Test
    func theNoticeSaysWhatHappensToChanges() {
        let message = SyncNotice.message(folder: "Vistara", state: .unreachable)
        #expect(message.contains("“Vistara” can’t be reached"))
        #expect(message.contains("written to the folder when it’s back"))
    }
}
