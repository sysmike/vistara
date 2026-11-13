import AppKit
import Foundation
import Testing
import VistaraCore
@testable import Vistara

@Suite
struct NewConnectionDefaultsTests {
    private func temporaryDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "vistara-tests-\(UUID().uuidString)"))
    }

    @Test
    func withNothingSavedTheBuiltInDefaultsApply() throws {
        let loaded = NewConnectionDefaults.load(from: try temporaryDefaults())
        #expect(loaded == NewConnectionDefaults())
        let draft = ConnectionDraft(defaults: loaded)
        #expect(draft.connection() == nil) // still needs a computer
        #expect(draft.resolutionMode == .matchWindow)
        #expect(draft.requiresNLA)
    }

    /// Defaults saved before a setting existed keep what they had; the new
    /// setting takes its default (#113).
    @Test
    func defaultsSavedBeforeASettingExistedStillLoad() throws {
        let store = try temporaryDefaults()
        let older = #"{"resolutionMode":"scaleToFit","usesHiDPI":false,"sharesClipboard":false}"#
        store.set(Data(older.utf8), forKey: NewConnectionDefaults.key)
        let loaded = NewConnectionDefaults.load(from: store)
        #expect(loaded.resolutionMode == .scaleToFit)
        #expect(!loaded.usesHiDPI)
        #expect(!loaded.sharesClipboard)
        #expect(!loaded.usesAllDisplays)
        #expect(loaded.requiresNLA)
    }

    @Test
    func savedDefaultsShapeEveryNewConnection() throws {
        let store = try temporaryDefaults()
        var defaults = NewConnectionDefaults()
        defaults.resolutionMode = .scaleToFit
        defaults.usesHiDPI = false
        defaults.usesAllDisplays = true
        defaults.sharesClipboard = false
        defaults.audioMode = .off
        defaults.reconnectsAutomatically = false
        defaults.requiresNLA = false
        defaults.certificatePolicy = .requireTrusted
        defaults.save(to: store)

        var draft = ConnectionDraft(defaults: .load(from: store))
        draft.host = "build01"
        let connection = try #require(draft.connection())
        #expect(connection.resolutionMode == .scaleToFit)
        #expect(!connection.usesHiDPI)
        #expect(connection.usesAllDisplays)
        #expect(!connection.sharesClipboard)
        #expect(connection.audioMode == .off)
        #expect(!connection.reconnectsAutomatically)
        #expect(!connection.requiresNLA)
        #expect(connection.certificatePolicy == .requireTrusted)
    }

    @Test
    func aFixedSizeIsNeverADefault() {
        var defaults = NewConnectionDefaults()
        defaults.resolutionMode = .fixed
        #expect(ConnectionDraft(defaults: defaults).resolutionMode == .matchWindow)
    }

    @Test
    func unreadableDefaultsFallBackToTheBuiltInOnes() throws {
        let store = try temporaryDefaults()
        store.set(Data("not json".utf8), forKey: NewConnectionDefaults.key)
        #expect(NewConnectionDefaults.load(from: store) == NewConnectionDefaults())
    }
}

@Suite
@MainActor
struct DockMenuTests {
    @Test
    func openSessionsComeFirstThenFavorites() {
        let menu = DockMenu.make(
            sessions: [.init(title: "Build Server") {}],
            favorites: [.init(title: "Finance VM") {}, .init(title: "Lab Desktop") {}]
        )
        let titles = ["Open Sessions", "Build Server", "", "Favorites", "Finance VM", "Lab Desktop"]
        #expect(menu.items.map(\.title) == titles)
        #expect(menu.items[0].isSectionHeader)
        #expect(menu.items[2].isSeparatorItem)
    }

    @Test
    func anEmptyListLeavesItsSectionOut() {
        #expect(DockMenu.make(sessions: [], favorites: []).items.isEmpty)
        let favoritesOnly = DockMenu.make(sessions: [], favorites: [.init(title: "Finance VM") {}])
        #expect(favoritesOnly.items.map(\.title) == ["Favorites", "Finance VM"])
    }

    @Test
    func choosingAnItemDoesWhatItSays() throws {
        var chosen: [String] = []
        let menu = DockMenu.make(
            sessions: [.init(title: "Build Server") { chosen.append("show") }],
            favorites: [.init(title: "Finance VM") { chosen.append("connect") }]
        )
        for item in menu.items where !item.isSectionHeader && !item.isSeparatorItem {
            // Compared, not sent: a selector taken through #require arrived
            // at the target unrecognized and stopped the test host.
            #expect(item.action == #selector(DockMenuTarget.perform(_:)))
            let target = try #require(item.target as? DockMenuTarget)
            target.perform(item)
        }
        #expect(chosen == ["show", "connect"])
    }
}

@Suite
@MainActor
struct HelpTests {
    @Test
    func vistaraHelpOpensTheUserGuide() throws {
        let guide = try #require(HelpCommands.guide)
        #expect(guide.scheme == "https")
        #expect(guide.path.hasSuffix("/docs/USER-GUIDE.md"))
    }
}
