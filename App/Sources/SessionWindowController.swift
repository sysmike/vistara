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
    /// Shared by every session window and no other.
    static let tabbingIdentifier = "io.github.sysmike.vistara.session"

    let model: SessionModel
    let window: NSWindow
    var onMainChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private var changedCertificateAlert: NSAlert?

    init(model: SessionModel) {
        self.model = model
        window = SessionWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        lastPhase = model.phase
        tabState = SessionTabState.of(model)
        super.init()

        let target = model.target
        window.isReleasedWhenClosed = false
        // Session windows group as tabs with each other, and only with each
        // other (docs/DESIGN.md, Session tabs).
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .automatic
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
        model.isInFront = { [weak self] in
            guard let self else { return false }
            return window.isKeyWindow || (span?.hasKeyWindow ?? false)
        }
        model.windowDesktopSize = { [weak window, weak model] in
            guard let window, let model else { return nil }
            return DesktopSize.filling(
                viewSize: window.contentLayoutRect.size,
                backingScale: window.backingScaleFactor,
                usesHiDPI: model.target.usesHiDPI
            )
        }
        updateTitle()
        window.tab.accessoryView = tabState.makeView()
        observePhase()
        if target.usesAllDisplays {
            startSpanIfPossible()
            observeDisplays()
        }
    }

    /// The windows on the other displays, while the session spans them.
    /// See DisplaySpan.swift.
    var span: DisplaySpan?
    /// Display changes, followed while the session is meant for all displays.
    var displayObserver: (any NSObjectProtocol)?
    var pendingDisplayChange: Task<Void, Never>?
    /// The span gave way because only one display was left, and comes back
    /// with a second one. Not after the user left full screen.
    var spanWaitsForDisplays = false

    /// What the tab and VoiceOver were last told.
    private var lastPhase: SessionModel.Phase
    private var tabState: SessionTabState

    /// Watches the session's state for its tab and for VoiceOver. Here, not
    /// in the window's SwiftUI content, so that a tab in the background,
    /// whose window is ordered out, still says what happened.
    private func observePhase() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.phaseChanged()
                self?.observePhase()
            }
        }
    }

    private func phaseChanged() {
        let phase = model.phase
        let state = SessionTabState.of(model)
        if state != tabState {
            tabState = state
            window.tab.accessoryView = state.makeView()
        }
        defer { lastPhase = phase }
        guard SessionAnnouncement.kind(of: lastPhase) != SessionAnnouncement.kind(of: phase) else { return }
        var message: DisconnectMessage?
        if case .disconnected(let reason) = phase { message = model.disconnectMessage(for: reason) }
        let name = model.target.name
        guard var text = SessionAnnouncement.text(for: phase, name: name, message: message) else { return }
        // A tab in the background says whose session it is.
        let isInFront = window.isVisible && (window.tabGroup?.selectedWindow ?? window) === window
        if !isInFront, !text.contains(name) { text = "\(name): \(text)" }
        SessionAnnouncement.post(text)
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
        if let span {
            showSpan(span)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
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
        // A tab brought to the front of a full-screen window is full screen
        // too, without having entered it itself.
        model.isFullScreen = window.styleMask.contains(.fullScreen)
        onMainChange?(true)
        // Every tab of the window, also one that was never in front.
        for tab in window.tabbedWindows ?? [window] {
            (tab.delegate as? SessionWindowController)?.updateVisibility()
        }
    }

    /// Also when another tab of the same window is chosen.
    func windowDidResignMain(_ notification: Notification) {
        onMainChange?(false)
        updateVisibility()
    }

    /// A background tab, a minimized window, or one entirely covered: nobody
    /// sees the session, so the server need not send its screen. AppKit says
    /// so in several ways and orders a tab out only after another is chosen,
    /// so the answer is read once things have settled.
    func updateVisibility() {
        Task { @MainActor [weak self] in self?.readVisibility() }
    }

    private func readVisibility() {
        let isSelectedTab = (window.tabGroup?.selectedWindow ?? window) === window
        let isVisible = window.isVisible && isSelectedTab && !window.isMiniaturized
            && window.occlusionState.contains(.visible) || (span?.hasVisibleWindow ?? false)
        // The model sends only when this changes.
        if model.isVisible != isVisible { model.isVisible = isVisible }
    }

    /// The one event a tab hears when Merge All Windows or a new tab puts it
    /// in the background without its ever having been in front.
    func windowDidUpdate(_ notification: Notification) {
        readVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateVisibility()
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
        endSpan()
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
        span?.close()
        span = nil
        stopObservingDisplays()
        onClose?()
    }
}

/// A session window. It remembers its size and position for its computer
/// only while it is alone: a tab group's frame belongs to the group, not to
/// any one computer (docs/DESIGN.md, Session tabs).
final class SessionWindow: NSWindow {
    var isTabbed: Bool {
        (tabbedWindows?.count ?? 1) > 1
    }

    override func saveFrame(usingName name: NSWindow.PersistableFrameDescriptor) {
        guard !isTabbed else { return }
        super.saveFrame(usingName: name)
    }

    /// File > Close is Close Tab in a tabbed window (HIG The menu bar, File
    /// menu). AppKit leaves the title as it is, so the window sets it as the
    /// menu is validated.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) {
            menuItem.title = isTabbed ? "Close Tab" : Self.closeTitle
        }
        return super.validateMenuItem(menuItem)
    }

    static let closeTitle = "Close"

    /// Asked before the menus. Control-Tab goes to a session that has the
    /// keyboard; Shift-Command-] and [ show the next and previous tab, as in
    /// other Mac apps with tabs (docs/DESIGN.md, Keyboard).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let session = firstResponder as? RDPSessionView, session.takesControlTab(event) {
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, isTabbed, modifiers == [.command, .shift] {
            switch event.characters(byApplyingModifiers: []) {
            case "]":
                selectNextTab(nil)
                return true
            case "[":
                selectPreviousTab(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The Connections window, Settings, and any other window never become a
    /// tab: each is set so as it first becomes key, before anyone can merge
    /// or drag it. SwiftUI makes those windows, so this is where Vistara
    /// meets them.
    @MainActor
    static func keepOtherWindowsFromTabbing() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            // Delivered on the main queue, where the window lives.
            nonisolated(unsafe) let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                refuseTabbing(window)
                restoreCloseTitle(for: window)
            }
        }
        for window in NSApp.windows {
            refuseTabbing(window)
        }
    }

    /// Any other window in front: File > Close is Close again.
    @MainActor
    static func restoreCloseTitle(for window: NSWindow?) {
        guard let window, !(window is SessionWindow) else { return }
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        for item in items where item.action == #selector(NSWindow.performClose(_:)) && item.title != closeTitle {
            item.title = closeTitle
        }
    }

    @MainActor
    static func refuseTabbing(_ window: NSWindow?) {
        guard let window, !(window is SessionWindow), window.tabbingMode != .disallowed else { return }
        window.tabbingMode = .disallowed
    }
}
