import CoreGraphics

/// Where the remote desktop sits inside a view: scaled to fit, centred, and
/// never stretched.
enum FitLayout {
    /// Size of the desktop's quad in normalized device coordinates, where 1
    /// means "fills the view" along that axis. One axis is always 1 unless a
    /// size is empty.
    static func scale(content: CGSize, container: CGSize) -> SIMD2<Float> {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return SIMD2(0, 0)
        }
        let factor = min(container.width / content.width, container.height / content.height)
        return SIMD2(
            Float(content.width * factor / container.width),
            Float(content.height * factor / container.height)
        )
    }

    /// The desktop's frame inside the container, in the container's units.
    static func frame(content: CGSize, container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let factor = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * factor, height: content.height * factor)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
