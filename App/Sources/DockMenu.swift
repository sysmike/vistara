import AppKit
import VistaraCore

/// The Dock menu: open sessions, to bring forward, and favorites, to connect
/// (docs/DESIGN.md, Menu bar).
@MainActor
enum DockMenu {
    struct Entry {
        let title: String
        let perform: () -> Void
    }

    static func make(sessions: [Entry], favorites: [Entry]) -> NSMenu {
        let menu = NSMenu()
        if !sessions.isEmpty {
            menu.addItem(.sectionHeader(title: "Open Sessions"))
            sessions.forEach { menu.addItem(item($0)) }
        }
        if !favorites.isEmpty {
            if !sessions.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: "Favorites"))
            favorites.forEach { menu.addItem(item($0)) }
        }
        return menu
    }

    /// The menu for what is open and saved now.
    static func current() -> NSMenu {
        let coordinator = SessionCoordinator.shared
        let library = LibraryModel.shared
        let sessions = coordinator.sessionWindows.map { controller in
            Entry(title: controller.window.title) { controller.show() }
        }
        let favorites = library.library.connections
            .filter(\.isFavorite)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { connection in
                Entry(title: SessionTarget(connection: connection).name) {
                    coordinator.open(SessionTarget(connection: connection))
                    Task { await library.recordConnection(connection.id) }
                }
            }
        return make(sessions: sessions, favorites: favorites)
    }

    private static func item(_ entry: Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(DockMenuTarget.perform(_:)), keyEquivalent: "")
        item.target = DockMenuTarget.shared
        item.representedObject = DockMenuTarget.Action(entry.perform)
        return item
    }
}

/// Runs the action a Dock menu item carries.
@MainActor
final class DockMenuTarget: NSObject {
    static let shared = DockMenuTarget()

    final class Action: NSObject {
        let perform: () -> Void

        init(_ perform: @escaping () -> Void) {
            self.perform = perform
        }
    }

    @objc func perform(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.perform()
    }
}
