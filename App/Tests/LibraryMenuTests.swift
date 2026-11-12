import AppKit
import Testing
@testable import Vistara

/// The commands the design's menu table asks for.
@Suite
@MainActor
struct LibraryMenuTests {
    private func item(_ title: String, in menu: String) -> NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.title == menu }?.submenu?.items.first { $0.title == title }
    }

    private func modifiers(_ item: NSMenuItem?) -> NSEvent.ModifierFlags? {
        item?.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
    }

    @Test
    func fileHasNewConnectionWithCommandN() {
        let newConnection = item("New Connection…", in: "File")
        #expect(newConnection?.keyEquivalent == "n")
        #expect(modifiers(newConnection) == .command)
    }

    @Test
    func editHasFindWithCommandF() {
        let find = item("Find", in: "Edit")
        #expect(find?.keyEquivalent == "f")
        #expect(modifiers(find) == .command)
    }

    @Test
    func viewCanHideTheSidebar() {
        let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items ?? []
        let sidebar = view.first { $0.title.contains("Sidebar") }
        #expect(sidebar != nil, "View: \(view.map(\.title))")
        #expect(sidebar?.keyEquivalent == "s")
        #expect(modifiers(sidebar) == [.control, .command])
    }

    @Test
    func windowHasConnectionsWithCommandZero() {
        let window = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
        window?.delegate?.menuNeedsUpdate?(window!)
        window?.update()
        let described = (window?.items ?? []).map {
            "\($0.title)[\($0.keyEquivalent)]<\($0.action.map(NSStringFromSelector) ?? "nil")>"
        }
        let connections = window?.items.first { $0.title == "Connections" }
        #expect(connections != nil, "Window: \(described)")
        #expect(connections?.keyEquivalent == "0")
        #expect(modifiers(connections) == .command)
    }
}
