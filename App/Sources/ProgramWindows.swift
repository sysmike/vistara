import AppKit
import RDPKit
import RDPKitUI

/// The windows of a RemoteApp session's programs (docs/DESIGN.md,
/// RemoteApp), each a Mac window, as the remote computer describes them.
@MainActor
final class ProgramWindows {
    private(set) var controllers: [UInt32: ProgramWindowController] = [:]
    let space: RemoteAppSpace
    private let desktop: RDPSharedDesktop
    private let connectionName: String
    private let send: ([RDPInputEvent]) -> Void
    /// The programs' last window has been gone a while: the session can end.
    var onLastWindowClosed: (() -> Void)?
    private var tasks: [Task<Void, Never>] = []
    /// Whether a window was brought to the front yet, which the first one is.
    private var hasShownWindow = false

    init(
        framebuffer: RDPFramebuffer, space: RemoteAppSpace, connectionName: String,
        send: @escaping ([RDPInputEvent]) -> Void
    ) {
        desktop = RDPSharedDesktop(framebuffer: framebuffer)
        self.space = space
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
        }
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
        case .programStarted, .programFailed:
            break
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
        for controller in controllers.values { controller.close() }
        controllers = [:]
    }
}
