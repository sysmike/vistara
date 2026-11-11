import AppKit
import SwiftUI

/// One session in one ordinary window: system title bar, no toolbar, the
/// desktop fills the content area.
@MainActor
final class SessionWindowController: NSObject, NSWindowDelegate {
    static let defaultContentSize = NSSize(width: 1280, height: 800)
    static let minimumContentSize = NSSize(width: 480, height: 320)

    let model: SessionModel
    let window: NSWindow
    var onMainChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    init(model: SessionModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        let target = model.target
        window.isReleasedWhenClosed = false
        window.title = target.name
        // Session tabs are a later feature (issue #37).
        window.tabbingMode = .disallowed

        let content = NSHostingView(rootView: SessionContentView(model: model))
        // The window decides its size, not the content.
        content.sizingOptions = []
        window.contentView = content
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(Self.fittingContentSize(on: window.screen ?? NSScreen.main))
        window.center()
        // Restores size and position from the last window for this computer.
        window.setFrameAutosaveName("Session \(target.host):\(target.port)")
        window.delegate = self
        if target.name != target.host {
            window.subtitle = target.host
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// The default size, or less on a small screen.
    static func fittingContentSize(on screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame.size else { return defaultContentSize }
        let titleBarAllowance: CGFloat = 40
        return NSSize(
            width: max(minimumContentSize.width, min(defaultContentSize.width, visible.width)),
            height: max(minimumContentSize.height, min(defaultContentSize.height, visible.height - titleBarAllowance))
        )
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        onMainChange?(true)
    }

    func windowDidResignMain(_ notification: Notification) {
        onMainChange?(false)
    }

    /// Closing disconnects without asking: the remote session keeps running
    /// and Reconnect brings it back.
    func windowWillClose(_ notification: Notification) {
        model.disconnect()
        onClose?()
    }
}
