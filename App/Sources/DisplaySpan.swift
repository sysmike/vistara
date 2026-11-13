import AppKit
import RDPKitUI
import SwiftUI

/// The windows of a session that spans displays, beyond its own window: one
/// on each other display, each showing its region of the remote desktop
/// (docs/DESIGN.md, Multiple displays). They are full screen together, never
/// tabs, and stay out of the Window menu, which lists the session once.
@MainActor
final class DisplaySpan: NSObject, NSWindowDelegate {
    private(set) var windows: [NSWindow] = []
    private weak var controller: SessionWindowController?

    init(controller: SessionWindowController, monitors: [DisplayLayout.Monitor], displays: [DisplayLayout.Display]) {
        self.controller = controller
        super.init()
        for (index, monitor) in monitors.enumerated() where index > 0 {
            let screen = NSScreen.screens.indices.contains(monitor.displayIndex)
                ? NSScreen.screens[monitor.displayIndex] : nil
            let window = NSWindow(
                contentRect: screen?.frame ?? displays[monitor.displayIndex].frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false, screen: screen
            )
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.title = controller.window.title
            let content = NSHostingView(rootView: SpanDisplayView(model: controller.model, monitorIndex: index))
            content.sizingOptions = []
            window.contentView = content
            window.delegate = self
            windows.append(window)
        }
    }

    var hasKeyWindow: Bool {
        windows.contains(where: \.isKeyWindow)
    }

    var hasVisibleWindow: Bool {
        windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    /// Closes the windows without ending the session.
    func close() {
        let closing = windows
        windows = []
        for window in closing {
            window.delegate = nil
            window.close()
        }
    }

    // MARK: NSWindowDelegate

    /// Closing any of the session's windows ends it.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
            windows.contains(where: { $0 === closing })
        else { return }
        // Already closing: the session's close must not close it again.
        windows.removeAll { $0 === closing }
        controller?.window.close()
    }

    /// Leaving full screen on one display leaves it on all.
    func windowDidExitFullScreen(_ notification: Notification) {
        controller?.endSpan()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        controller?.onMainChange?(true)
        controller?.updateVisibility()
    }

    func windowDidUpdate(_ notification: Notification) {
        controller?.updateVisibility()
    }
}

extension SessionWindowController {
    /// The Mac's displays. Tests give simulated ones; CI has one display.
    static var displays: () -> [DisplayLayout.Display] = { MacDisplays.current() }
    /// Whether each display has its own Spaces, which the system's full
    /// screen on several displays needs.
    static var displaysHaveSeparateSpaces: () -> Bool = { NSScreen.screensHaveSeparateSpaces }
    /// Off in tests, which cannot enter full screen on simulated displays.
    static var spansEnterFullScreen = true

    /// Lays the session out across all displays, when there are several and
    /// each has its own Spaces; otherwise it stays in this window.
    func startSpanIfPossible() {
        let displays = Self.displays()
        guard displays.count > 1, Self.displaysHaveSeparateSpaces() else { return }
        let monitors = DisplayLayout.monitors(for: displays, usesHiDPI: model.target.usesHiDPI)
        guard monitors.count > 1 else { return }
        model.displayMonitors = monitors
        window.tabbingMode = .disallowed
        span = DisplaySpan(controller: self, monitors: monitors, displays: displays)
        // This window shows the primary monitor, on the main display.
        let primary = monitors[0].displayIndex
        if NSScreen.screens.indices.contains(primary) {
            window.setFrame(NSScreen.screens[primary].visibleFrame, display: false)
        }
    }

    func showSpan(_ span: DisplaySpan) {
        window.makeKeyAndOrderFront(nil)
        for other in span.windows {
            other.orderFront(nil)
        }
        guard Self.spansEnterFullScreen else { return }
        for each in [window] + span.windows where !each.styleMask.contains(.fullScreen) {
            each.toggleFullScreen(nil)
        }
    }

    // MARK: Displays that change

    /// How long the displays have to rest before the session follows, as a
    /// window's size does.
    static var displayChangeDelay = Duration.milliseconds(250)

    func observeDisplays() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysMayHaveChanged() }
        }
    }

    func stopObservingDisplays() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        pendingDisplayChange?.cancel()
        pendingDisplayChange = nil
    }

    /// A burst of changes is followed once, after it has rested.
    private func displaysMayHaveChanged() {
        pendingDisplayChange?.cancel()
        let delay = Self.displayChangeDelay
        pendingDisplayChange = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.followDisplays()
        }
    }

    /// Displays added, removed, or rearranged: a window on each, and the
    /// new layout for the server. Left with one, the session goes on in full
    /// screen on it; given a second again, it spans them again.
    func followDisplays() {
        let displays = Self.displays()
        let canSpan = displays.count > 1 && Self.displaysHaveSeparateSpaces()
        if span != nil, !canSpan {
            span?.close()
            span = nil
            model.displayMonitors = []
            spanWaitsForDisplays = true
        } else if canSpan, span != nil || spanWaitsForDisplays {
            let monitors = DisplayLayout.monitors(for: displays, usesHiDPI: model.target.usesHiDPI)
            guard monitors != model.displayMonitors else { return }
            spanWaitsForDisplays = false
            span?.close()
            model.displayMonitors = monitors
            let rebuilt = DisplaySpan(controller: self, monitors: monitors, displays: displays)
            span = rebuilt
            window.tabbingMode = .disallowed
            for other in rebuilt.windows {
                other.orderFront(nil)
                if Self.spansEnterFullScreen { other.toggleFullScreen(nil) }
            }
        }
        model.requestDisplayLayout()
    }

    /// Leaves the other displays and full screen: the session goes on in
    /// this window, and its desktop follows the window again.
    func endSpan() {
        // The user's choice: no coming back when displays change.
        spanWaitsForDisplays = false
        guard let span else { return }
        self.span = nil
        model.displayMonitors = []
        model.requestDisplayLayout()
        span.close()
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.tabbingMode = .automatic
        window.makeKeyAndOrderFront(nil)
    }
}

/// The Mac's displays as DisplayLayout takes them.
enum MacDisplays {
    @MainActor
    static func current() -> [DisplayLayout.Display] {
        // The first screen is the one with the menu bar.
        NSScreen.screens.enumerated().map { index, screen in
            // A full-screen window stays below a camera housing.
            let top = screen.safeAreaInsets.top
            return DisplayLayout.Display(
                frame: screen.frame, backingScale: screen.backingScaleFactor, isMain: index == 0,
                usableSize: top > 0 ? CGSize(width: screen.frame.width, height: screen.frame.height - top) : nil
            )
        }
    }
}
