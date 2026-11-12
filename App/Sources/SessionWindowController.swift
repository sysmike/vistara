import AppKit
import Observation
import RDPKitUI
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
    private var changedCertificateAlert: NSAlert?

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
        // Session tabs are a later feature (issue #37).
        window.tabbingMode = .disallowed
        // The system's own full screen: the green button, View > Enter Full
        // Screen, and its shortcut. The window gets a Space of its own, the
        // menu bar appears at the top edge, and the system keeps clear of a
        // camera housing. The desktop follows the new size like any resize.
        window.collectionBehavior.insert(.fullScreenPrimary)

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
        model.windowDesktopSize = { [weak window, weak model] in
            guard let window, let model else { return nil }
            return DesktopSize.filling(
                viewSize: window.contentLayoutRect.size,
                backingScale: window.backingScaleFactor,
                usesHiDPI: model.target.usesHiDPI
            )
        }
        updateTitle()
    }

    /// The connection's name, and the host when that says something more.
    func updateTitle() {
        let target = model.target
        window.title = target.name
        window.subtitle = target.name == target.host ? "" : target.host
    }

    /// Starts watching for a changed certificate, which is shown as an alert
    /// on this window. Unknown certificates are a sheet in the content view.
    func observeCertificates() {
        withObservationTracking {
            _ = model.pendingCertificate
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.pendingCertificateChanged()
                self?.observeCertificates()
            }
        }
    }

    private func pendingCertificateChanged() {
        guard let certificate = model.pendingCertificate, certificate.previousFingerprint != nil else {
            // Answered or gone with the session: take the alert down.
            if let alert = changedCertificateAlert {
                changedCertificateAlert = nil
                window.endSheet(alert.window)
            }
            return
        }
        guard changedCertificateAlert == nil else { return }
        let alert = ChangedCertificateAlert.make(certificate: certificate, name: model.target.name)
        changedCertificateAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.changedCertificateAlert === alert else { return }
                self.changedCertificateAlert = nil
                let isConnect = response == ChangedCertificateAlert.connectResponse
                self.model.answerCertificate(isConnect ? .trustOnce : .cancel)
            }
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

    /// Enters or leaves the system's full screen.
    func toggleFullScreen() {
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        model.isFullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        model.isFullScreen = false
    }

    // A transition the system could not finish leaves the window as it was.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        model.isFullScreen = window.styleMask.contains(.fullScreen)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        model.isFullScreen = window.styleMask.contains(.fullScreen)
    }

    /// Closing disconnects without asking: the remote session keeps running
    /// and Reconnect brings it back.
    func windowWillClose(_ notification: Notification) {
        model.disconnect()
        onClose?()
    }
}
