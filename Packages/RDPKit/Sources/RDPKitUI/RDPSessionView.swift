import AppKit
import MetalKit
import RDPKit

/// Shows a session's remote desktop, scaled to fit the view.
///
/// The view draws only when the desktop changed or the view needs
/// redisplay; an idle session costs nothing. All drawing happens on the main
/// thread and never waits for the session thread.
public final class RDPSessionView: MTKView {
    /// Used in the accessibility label, for example "Remote desktop, Build Server".
    public var connectionName: String {
        didSet { setAccessibilityLabel(Self.accessibilityLabel(for: connectionName)) }
    }

    /// Number of frames drawn so far. For tests and diagnostics.
    public private(set) var drawCount = 0

    private let framebuffer: RDPFramebuffer
    private let renderer: FrameRenderer?
    private var observation: Task<Void, Never>?

    public init(framebuffer: RDPFramebuffer, connectionName: String) {
        self.framebuffer = framebuffer
        self.connectionName = connectionName
        let device = MTLCreateSystemDefaultDevice()
        renderer = device.flatMap { try? FrameRenderer(device: $0) }
        super.init(frame: .zero, device: device)

        colorPixelFormat = FrameRenderer.pixelFormat
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Remote desktops are sRGB. Declaring it lets the system match colours
        // on wide-gamut displays instead of oversaturating them.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Draw on demand only.
        isPaused = true
        enableSetNeedsDisplay = true

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(Self.accessibilityLabel(for: connectionName))
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("RDPSessionView is created in code")
    }

    static func accessibilityLabel(for connectionName: String) -> String {
        // Localization arrives with the app's string catalog.
        "Remote desktop, \(connectionName)"
    }

    /// The remote desktop's frame inside the view, in view coordinates.
    public var desktopFrame: CGRect {
        FitLayout.frame(content: renderer?.desktopSize ?? .zero, container: bounds.size)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.cancel()
        observation = nil
        guard window != nil else { return }

        consumeUpdate()
        let changes = framebuffer.changes
        observation = Task { [weak self] in
            for await _ in changes {
                self?.consumeUpdate()
            }
        }
    }

    /// Uploads whatever changed and asks for one redraw.
    func consumeUpdate() {
        guard let renderer, let update = framebuffer.takeUpdate() else { return }
        if renderer.apply(update) {
            needsDisplay = true
        }
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let renderer, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let commandBuffer = renderer.draw(pass: pass, targetSize: drawableSize)
        else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        drawCount += 1
    }
}
