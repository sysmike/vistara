import Foundation

/// The pointer shape the remote computer wants shown.
public enum RDPCursor: Sendable, Equatable {
    /// The system's standard arrow.
    case systemDefault
    case hidden
    case image(RDPCursorImage)
}

public struct RDPCursorImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// The pixel that points, counted from the top left.
    public var hotspotX: Int
    public var hotspotY: Int
    /// `width * height` pixels of 32-bit BGRA with straight alpha, top row first.
    public var pixels: Data

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }
}
