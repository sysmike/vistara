import AppKit
import RDPKit
import RDPKitUI

/// The windows of a RemoteApp session's programs (docs/DESIGN.md,
/// RemoteApp), each a Mac window, as the remote computer describes them.
@MainActor
final class ProgramWindows {
    private(set) var controllers: [UInt32: ProgramWindowController] = [:]
    /// The displays as the remote desktop has them now.
    private(set) var space: RemoteAppSpace
    private let usesHiDPI: Bool
    private let framebuffer: RDPFramebuffer
    private let desktop: RDPSharedDesktop
    private let connectionName: String
    private let send: ([RDPInputEvent]) -> Void
    /// The programs' last window has been gone a while: the session can end.
    var onLastWindowClosed: (() -> Void)?
    /// The remote computer answered a program's start: nil when it started.
    var onProgramAnswer: ((RDPProgramFailure?) -> Void)?
    /// A window of its own (not a menu or a dialog's) showed its icon first.
    var onWindowIcon: ((RDPImage) -> Void)?
    private var iconsTold: Set<UInt32> = []
    private var displayObserver: (any NSObjectProtocol)?
    private var displayChange: Task<Void, Never>?
    /// How long display changes rest before they are followed.
    static var displayChangeDelay = Duration.milliseconds(500)
    /// How long the remote computer has to take on a new layout.
    static var layoutWait = Duration.seconds(5)
    private var tasks: [Task<Void, Never>] = []
    /// Whether a window was brought to the front yet, which the first one is.
    private var hasShownWindow = false

    init(
        framebuffer: RDPFramebuffer, space: RemoteAppSpace, usesHiDPI: Bool, connectionName: String,
        send: @escaping ([RDPInputEvent]) -> Void
    ) {
        desktop = RDPSharedDesktop(framebuffer: framebuffer)
        self.framebuffer = framebuffer
        self.space = space
        self.usesHiDPI = usesHiDPI
        self.connectionName = connectionName
        self.send = send
    }

    /// Follows a session's windows and events until it ends.
    func follow(_ session: RDPSession) {
        let windows = session.remoteWindows
        let events = session.remoteAppEvents
        tasks.append(Task { [weak self] in
            for await batch in windows { self?.apply(batch) }
        })
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        // A maximized window leaves the menu bar and the Dock visible.
        send([.remoteApp(.workArea(space.workArea))])
        followDisplays()
    }

    // MARK: Displays

    /// Displays plugged in or out, rearranged, or resized while the program
    /// runs: followed once a burst of changes has rested.
    private func followDisplays() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysMayHaveChanged() }
        }
    }

    func displaysMayHaveChanged() {
        displayChange?.cancel()
        let delay = Self.displayChangeDelay
        displayChange = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.displaysChanged()
        }
    }

    /// Asks the remote computer for the new layout. Windows keep their place
    /// on the Mac, those whose display went away moved onto the main one,
    /// until the remote desktop has the new size; then the new arrangement
    /// takes over, and windows are put where the Mac has them. A remote
    /// computer that keeps its desktop keeps the old arrangement.
    private func displaysChanged() async {
        let next = RemoteAppSpace.current(usesHiDPI: usesHiDPI)
        guard next != space else { return }
        for controller in controllers.values where controller.window.takesKeyboard {
            controller.holdPlace(
                at: RemoteAppSpace.placement(
                    of: controller.window.frame, on: next.displays, visibleMain: next.visibleMain
                )
            )
        }
        send([.monitorLayout(next.monitors)])
        let box = next.boundingBox
        let deadline = ContinuousClock.now + Self.layoutWait
        var adopted = false
        while !Task.isCancelled {
            let size = framebuffer.size
            adopted = size.width == box.width && size.height == box.height
            if adopted || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
        if adopted {
            space = next
            send([.remoteApp(.workArea(next.workArea))])
        }
        for controller in controllers.values { controller.releasePlace(in: space) }
    }

    /// Windows that changed, owners before what they own.
    func apply(_ batch: [RDPRemoteWindow]) {
        let ordered = batch.sorted { ($0.ownerID == nil ? 0 : 1) < ($1.ownerID == nil ? 0 : 1) }
        for remote in ordered {
            if remote.isDeleted {
                controllers.removeValue(forKey: remote.id)?.close()
            } else if let controller = controllers[remote.id] {
                controller.apply(remote)
            } else {
                open(remote)
            }
            if remote.ownerID == nil, !remote.isDeleted, let icon = remote.icon, iconsTold.insert(remote.id).inserted {
                onWindowIcon?(icon)
            }
        }
    }

    /// Brings the windows forward, as when a running program is opened again.
    func bringToFront() {
        NSApp.activate()
        let shown = controllers.values.filter { $0.window.takesKeyboard && $0.window.isVisible }
        shown.forEach { $0.window.orderFront(nil) }
        shown.first?.window.makeKeyAndOrderFront(nil)
    }

    private func open(_ remote: RDPRemoteWindow) {
        let controller = ProgramWindowController(
            remote: remote, desktop: desktop, space: space, connectionName: connectionName, send: send
        )
        controllers[remote.id] = controller
        guard remote.showState != .hidden else { return }
        if let owner = remote.ownerID.flatMap({ controllers[$0] }) {
            // Above the window it belongs to, and gone with it.
            owner.window.addChildWindow(controller.window, ordered: .above)
        }
        if controller.window.takesKeyboard, !hasShownWindow {
            hasShownWindow = true
            NSApp.activate()
            controller.window.makeKeyAndOrderFront(nil)
        } else {
            controller.window.orderFront(nil)
        }
    }

    func handle(_ event: RDPRemoteAppEvent) {
        switch event {
        case .moveSizeBegan(let id, let kind, let x, let y):
            controllers[id]?.beginLocalDrag(kind, at: (x, y))
        case .moveSizeEnded(let id, _, _):
            controllers[id]?.endLocalDrag()
        case .sizeLimits(let id, let limits):
            controllers[id]?.applyLimits(limits)
        case .lastWindowClosed:
            onLastWindowClosed?()
        case .programStarted:
            onProgramAnswer?(nil)
        case .programFailed(let failure):
            onProgramAnswer?(failure)
        }
    }

    /// Whether any of the windows is shown.
    var hasVisibleWindow: Bool {
        controllers.values.contains { $0.window.isVisible }
    }

    func dim(_ isDimmed: Bool) {
        for controller in controllers.values { controller.dim(isDimmed) }
    }

    /// Closes every window and stops following the session.
    func closeAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
        displayChange?.cancel()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        for controller in controllers.values { controller.close() }
        controllers = [:]
    }
}
