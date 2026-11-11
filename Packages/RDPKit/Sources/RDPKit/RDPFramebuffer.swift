import Foundation
import os

/// Pixels that changed, ready to upload to a texture.
public struct RDPFrameUpdate: Sendable, Equatable {
    /// Size of the whole remote desktop. When it differs from the previous
    /// update, the desktop was resized and this update covers all of it.
    public let desktopWidth: Int
    public let desktopHeight: Int
    /// The changed area, origin at the top left.
    public let rect: RDPFramebuffer.Rect
    /// The changed area's pixels: 32-bit BGRA, top row first, `rect.width * 4`
    /// bytes per row with no padding.
    public let pixels: Data
}

/// The remote desktop's pixels, shared between the session thread, which
/// writes, and the UI, which reads.
///
/// Changes are coalesced: however many times the session paints between two
/// calls to `takeUpdate()`, the reader gets one update covering all of it.
/// Neither side waits for the other beyond the time it takes to copy the
/// changed pixels.
public final class RDPFramebuffer: Sendable {
    public struct Rect: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// The smallest rectangle that contains both.
        func union(_ other: Rect) -> Rect {
            let left = min(x, other.x)
            let top = min(y, other.y)
            let right = max(x + width, other.x + other.width)
            let bottom = max(y + height, other.y + other.height)
            return Rect(x: left, y: top, width: right - left, height: bottom - top)
        }

        /// The part inside a desktop of the given size, or nil if none is.
        func clipped(toWidth desktopWidth: Int, height desktopHeight: Int) -> Rect? {
            let left = max(x, 0)
            let top = max(y, 0)
            let right = min(x + width, desktopWidth)
            let bottom = min(y + height, desktopHeight)
            guard right > left, bottom > top else { return nil }
            return Rect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    private struct Storage {
        var width = 0
        var height = 0
        /// BGRA, `width * 4` bytes per row.
        var pixels: [UInt8] = []
        var dirty: Rect?
    }

    static let bytesPerPixel = 4

    /// Yields whenever there is something new for `takeUpdate()`. Several
    /// changes may produce one element. Ends when the session ends. Intended
    /// for a single consumer.
    public let changes: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.changes = stream
        self.continuation = continuation
    }

    /// Current size of the remote desktop, zero before the first paint.
    public var size: (width: Int, height: Int) {
        storage.withLock { ($0.width, $0.height) }
    }

    /// Returns everything that changed since the last call, or nil if nothing did.
    public func takeUpdate() -> RDPFrameUpdate? {
        storage.withLock { storage -> RDPFrameUpdate? in
            guard let dirty = storage.dirty else { return nil }
            storage.dirty = nil

            let rowBytes = dirty.width * Self.bytesPerPixel
            var pixels = Data(capacity: rowBytes * dirty.height)
            for row in dirty.y..<(dirty.y + dirty.height) {
                let start = (row * storage.width + dirty.x) * Self.bytesPerPixel
                pixels.append(contentsOf: storage.pixels[start..<(start + rowBytes)])
            }
            return RDPFrameUpdate(
                desktopWidth: storage.width,
                desktopHeight: storage.height,
                rect: dirty,
                pixels: pixels
            )
        }
    }

    /// Copies the `dirty` part of a source framebuffer in. When the size
    /// differs from what is stored, everything is copied instead.
    ///
    /// `source` holds `height` rows of `stride` bytes, 32-bit BGRA.
    func write(from source: UnsafeBufferPointer<UInt8>, stride: Int, width: Int, height: Int, dirty: Rect) {
        guard width > 0, height > 0, stride >= width * Self.bytesPerPixel, source.count >= stride * height else {
            return
        }
        // Unchecked because the closure reads through `source`, a pointer the
        // caller guarantees for the duration of this call.
        let hasChanges = storage.withLockUnchecked { storage -> Bool in
            var area = dirty
            if storage.width != width || storage.height != height {
                storage.width = width
                storage.height = height
                storage.pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
                storage.dirty = nil
                area = Rect(x: 0, y: 0, width: width, height: height)
            }
            guard let area = area.clipped(toWidth: width, height: height) else { return false }

            let rowBytes = area.width * Self.bytesPerPixel
            for row in area.y..<(area.y + area.height) {
                let sourceStart = row * stride + area.x * Self.bytesPerPixel
                let targetStart = (row * width + area.x) * Self.bytesPerPixel
                storage.pixels.replaceSubrange(
                    targetStart..<(targetStart + rowBytes),
                    with: source[sourceStart..<(sourceStart + rowBytes)]
                )
            }
            storage.dirty = storage.dirty.map { $0.union(area) } ?? area
            return true
        }
        if hasChanges { continuation.yield() }
    }

    func finish() {
        continuation.finish()
    }
}
