import AppKit
import RDPKit

/// Makes Mac cursors from the shapes the remote computer sends.
@MainActor
enum CursorFactory {
    /// A cursor that shows nothing, for when the remote computer hides its own.
    static let hidden: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// The cursor to show over the desktop, or nil for the system's arrow.
    /// `pointsPerPixel` is how large one remote pixel is drawn, so the cursor
    /// is scaled with the desktop it points at.
    static func cursor(for cursor: RDPCursor, pointsPerPixel: CGFloat) -> NSCursor? {
        switch cursor {
        case .systemDefault:
            return nil
        case .hidden:
            return hidden
        case .image(let shape):
            guard let image = image(from: shape) else { return nil }
            let scale = pointsPerPixel > 0 ? pointsPerPixel : 1
            let size = NSSize(width: CGFloat(shape.width) * scale, height: CGFloat(shape.height) * scale)
            let hotSpot = NSPoint(x: CGFloat(shape.hotspotX) * scale, y: CGFloat(shape.hotspotY) * scale)
            return NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: hotSpot)
        }
    }

    /// The shape as an image. Nil when the pixels do not match the size.
    static func image(from shape: RDPCursorImage) -> CGImage? {
        guard shape.width > 0, shape.height > 0, shape.pixels.count == shape.width * shape.height * 4,
            let provider = CGDataProvider(data: shape.pixels as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        // BGRA in memory is ARGB read as little-endian words; alpha is straight.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)
        )
        return CGImage(
            width: shape.width,
            height: shape.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: shape.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
