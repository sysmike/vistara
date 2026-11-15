import AppKit
import MetalKit
import RDPKit

/// One remote desktop shown in several views, each its own region of it, as
/// a remote program's windows are (docs/DESIGN.md, RemoteApp). The pixels are
/// uploaded once, and every view draws from the same texture.
@MainActor
public final class RDPSharedDesktop {
    let framebuffer: RDPFramebuffer
    let device: (any MTLDevice)?
    let renderer: FrameRenderer?
    private let views = NSHashTable<RDPSessionView>.weakObjects()
    private var cursor = RDPCursor.systemDefault
    /// Ends with the session's framebuffer.
    private var observation: Task<Void, Never>?

    public init(framebuffer: RDPFramebuffer) {
        self.framebuffer = framebuffer
        device = MTLCreateSystemDefaultDevice()
        renderer = device.flatMap { try? FrameRenderer(device: $0) }
        consume()
        let changes = framebuffer.changes
        observation = Task { [weak self] in
            for await _ in changes {
                self?.consume()
            }
        }
    }

    /// A view that shows `region` of this desktop, in its pixels.
    public func makeView(region: CGRect, connectionName: String) -> RDPSessionView {
        let view = RDPSessionView(framebuffer: framebuffer, connectionName: connectionName, shared: self)
        view.region = region
        views.add(view)
        view.showRemoteCursor(cursor)
        return view
    }

    /// Uploads what changed and has every view drawn again.
    private func consume() {
        if let changed = framebuffer.takeCursor() {
            cursor = changed
            for view in views.allObjects { view.showRemoteCursor(changed) }
        }
        guard let renderer, let update = framebuffer.takeUpdate(), renderer.apply(update) else { return }
        for view in views.allObjects { view.needsDisplay = true }
    }
}
