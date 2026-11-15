import AppKit
import QuartzCore
import RDPKit
import RDPKitUI

/// One window of a remote program as a Mac window (docs/DESIGN.md,
/// RemoteApp): where the remote computer puts it, showing its part of the
/// remote desktop, and telling the remote computer what the Mac did with it.
@MainActor
final class ProgramWindowController: NSObject, NSWindowDelegate {
    let id: UInt32
    let window: ProgramWindow
    let view: RDPSessionView
    private(set) var remote: RDPRemoteWindow
    private let space: RemoteAppSpace
    private let send: ([RDPInputEvent]) -> Void
    private let connectionName: String
    /// The Mac changing the window itself, so its moves are not the user's.
    private var isApplying = false
    /// What the Window menu says, once the window is listed there.
    private var windowsItemTitle: String?

    init(
        remote: RDPRemoteWindow, desktop: RDPSharedDesktop, space: RemoteAppSpace, connectionName: String,
        send: @escaping ([RDPInputEvent]) -> Void
    ) {
        id = remote.id
        self.remote = remote
        self.space = space
        self.send = send
        self.connectionName = connectionName
        window = ProgramWindow(
            contentRect: space.screenRect(for: remote.frame), styleMask: [.borderless, .miniaturizable],
            backing: .buffered, defer: false
        )
        view = desktop.makeView(region: space.framebufferRegion(for: remote.frame), connectionName: connectionName)
        super.init()

        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.takesKeyboard = !remote.isPopup || remote.hasTitleBar
        window.collectionBehavior = window.takesKeyboard
            ? [.managed, .participatesInCycle, .fullScreenNone]
            : [.transient, .ignoresCycle, .fullScreenNone]
        let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        container.wantsLayer = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        window.delegate = self
        window.onClose = { [weak self] in self?.command(.close) }
        window.onMinimize = { [weak self] in self?.command(.minimize) }
        window.onLocalDragEnded = { [weak self] point in self?.localDragEnded(at: point) }
        apply(remote)
    }

    /// The remote computer described the window anew.
    func apply(_ remote: RDPRemoteWindow) {
        self.remote = remote
        isApplying = true
        defer { isApplying = false }
        let title = remote.title.isEmpty ? connectionName : remote.title
        window.title = title
        view.connectionName = "\(title), \(connectionName)"
        listInWindowsMenu(as: "\(title) — \(connectionName)")
        if let icon = remote.icon.flatMap(Self.image) { window.miniwindowImage = icon }
        // While the Mac drags it, the window goes where the pointer goes.
        if window.localDrag == nil {
            window.setFrame(space.screenRect(for: remote.frame), display: true)
            view.region = space.framebufferRegion(for: remote.frame)
        }
        applyShape()
        switch remote.showState {
        case .hidden:
            window.orderOut(nil)
        case .minimized:
            if window.isVisible, !window.isMiniaturized { window.miniaturize(nil) }
        case .maximized, .shown:
            if window.isMiniaturized { window.deminiaturize(nil) }
        }
    }

    /// The Window menu lists a window without a title bar only when asked.
    private func listInWindowsMenu(as title: String) {
        guard window.takesKeyboard, title != windowsItemTitle else { return }
        if windowsItemTitle == nil {
            window.isExcludedFromWindowsMenu = false
            NSApp.addWindowsItem(window, title: title, filename: false)
        } else {
            NSApp.changeWindowsItem(window, title: title, filename: false)
        }
        windowsItemTitle = title
    }

    /// Only the parts the remote computer says are visible show, so a window
    /// with rounded corners has them on the Mac too.
    private func applyShape() {
        guard let layer = window.contentView?.layer else { return }
        let frame = remote.frame
        let wholeFrame = remote.visibleRegion == [frame]
        guard !wholeFrame else {
            layer.mask = nil
            return
        }
        let path = CGMutablePath()
        let height = CGFloat(frame.height)
        for rect in remote.visibleRegion {
            // In the window's points, from its bottom left.
            path.addRect(CGRect(
                x: CGFloat(rect.x - frame.x) / space.scale,
                y: (height - CGFloat(rect.y - frame.y + rect.height)) / space.scale,
                width: CGFloat(rect.width) / space.scale, height: CGFloat(rect.height) / space.scale
            ))
        }
        let mask = CAShapeLayer()
        mask.path = path
        layer.mask = mask
        window.invalidateShadow()
    }

    /// How large the user may drag the window, in points.
    func applyLimits(_ limits: RDPWindowSizeLimits) {
        window.minSize = CGSize(
            width: CGFloat(limits.minimumWidth) / space.scale, height: CGFloat(limits.minimumHeight) / space.scale
        )
        if limits.maximumWidth > 0, limits.maximumHeight > 0 {
            window.maxSize = CGSize(
                width: CGFloat(limits.maximumWidth) / space.scale, height: CGFloat(limits.maximumHeight) / space.scale
            )
        }
    }

    /// The remote computer started moving or resizing the window, the
    /// pointer pressed at `remotePoint`: the Mac follows the pointer.
    func beginLocalDrag(_ kind: RDPMoveSizeKind, at remotePoint: (x: Int, y: Int)) {
        guard kind != .keyboardMove, kind != .keyboardSize else { return }
        let start = space.screenRect(for: RDPRect(x: remotePoint.x, y: remotePoint.y, width: 0, height: 0)).origin
        window.beginLocalDrag(kind, at: start)
    }

    /// The remote computer ended it first.
    func endLocalDrag() {
        guard window.localDrag != nil else { return }
        window.endLocalDrag()
        sendFrame()
    }

    private func localDragEnded(at point: CGPoint) {
        sendFrame()
        // The remote computer still holds the button down, and ends its move
        // when it is let go.
        let position = space.framebufferPoint(for: point)
        send([.pointerButton(.left, isDown: false, x: position.x, y: position.y)])
    }

    private func sendFrame() {
        send([.remoteApp(.move(windowID: id, frame: space.remoteRect(for: window.frame)))])
    }

    private func command(_ command: RDPWindowCommand) {
        send([.remoteApp(.command(command, windowID: id))])
    }

    func close() {
        window.delegate = nil
        NSApp.removeWindowsItem(window)
        window.close()
    }

    /// Dimmed while the session reconnects.
    func dim(_ isDimmed: Bool) {
        window.alphaValue = isDimmed ? 0.5 : 1
    }

    /// An icon as the Dock shows a minimized window's.
    static func image(_ icon: RDPImage) -> NSImage? {
        guard icon.width > 0, icon.height > 0, icon.pixels.count >= icon.width * icon.height * 4,
            let provider = CGDataProvider(data: icon.pixels as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        // BGRA in memory is ARGB read as little-endian words; alpha is straight.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue))
        guard let image = CGImage(
            width: icon.width, height: icon.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: icon.width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: icon.width, height: icon.height))
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        send([.remoteApp(.activate(windowID: id, isActive: true))])
    }

    func windowDidResignKey(_ notification: Notification) {
        send([.remoteApp(.activate(windowID: id, isActive: false))])
    }

    /// Back from the Dock: the program shows it again.
    func windowDidDeminiaturize(_ notification: Notification) {
        guard !isApplying else { return }
        command(.restore)
    }
}
