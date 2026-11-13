import AppKit
import SwiftUI

/// Renders views to PNG files so a person can look at each state.
///
/// In CI a helper outside the sandbox captures real windows with
/// `screencapture`, because Liquid Glass and other window-server effects are
/// missing from a view drawn offscreen. The test writes a request with its
/// window's number and waits for the picture. Without the helper, or for a
/// window larger than the screen, the view is drawn offscreen as before.
@MainActor
enum Screenshots {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-screenshots")
    /// Where requests go and pictures come back. The CI step serves it.
    static let captureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-capture")

    /// Whether the CI helper captures windows (VISTARA_SCREEN_CAPTURE=1).
    static var capturesWindows: Bool {
        ProcessInfo.processInfo.environment["VISTARA_SCREEN_CAPTURE"] == "1"
    }

    /// How the window around the view looks.
    enum Frame {
        /// A titled window with its controls and, for SwiftUI toolbars, the
        /// toolbar: a main window.
        case window(title: String)
        /// No title bar or window controls: a sheet's or a pane's content.
        case panel
    }

    /// Shows the view in a window of the given content size, captures it,
    /// and returns the file's size in bytes.
    @discardableResult
    static func write(
        _ view: some View, size: NSSize, name: String, dark: Bool = false, appearance: NSAppearance.Name? = nil,
        frame: Frame = .panel
    ) async throws -> Int {
        // A main window draws its own background, which glass reflects.
        var isPanel: Bool {
            if case .panel = frame { return true }
            return false
        }
        let content = view
            .frame(width: size.width, height: size.height)
            .background(isPanel ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        switch frame {
        case .window(let title):
            window.title = title
            window.toolbarStyle = .unified
            hosting.sceneBridgingOptions = [.toolbars, .title]
        case .panel:
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance ?? (dark ? .darkAqua : .aqua))
        window.contentView = hosting
        window.setContentSize(size)
        defer { window.close() }
        return try await write(window, name: name)
    }

    /// Captures a window that is set up but not yet shown.
    @discardableResult
    static func write(_ window: NSWindow, name: String) async throws -> Int {
        window.center()
        // Controls draw their key-window look only in the key window.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        // Glass and other effects settle over a few frames.
        try await Task.sleep(for: .milliseconds(capturesWindows ? 600 : 200))
        let fits = window.screen.map { window.frame.height <= $0.visibleFrame.height } ?? false
        if capturesWindows, fits, let bytes = try await capture(window, name: name) {
            return bytes
        }
        guard let view = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        return try write(view, name: name)
    }

    /// Asks the CI helper for a picture of the window, and waits for it.
    private static func capture(_ window: NSWindow, name: String) async throws -> Int? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let picture = captureDirectory.appendingPathComponent("\(name).png")
        try? fileManager.removeItem(at: picture)
        try Data("\(window.windowNumber)".utf8).write(to: captureDirectory.appendingPathComponent("\(name).request"))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: picture), !data.isEmpty {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("\(name).png"))
                return data.count
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Draws a view offscreen.
    @discardableResult
    static func write(_ view: NSView, name: String) throws -> Int {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return data.count
    }
}
