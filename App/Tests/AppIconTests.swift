import AppKit
import Testing

/// The app carries its own icon, not the generic one.
@Suite
@MainActor
struct AppIconTests {
    @Test
    func theBundleNamesItsIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
    }

    /// Built from the Icon Composer file, the icon comes in the sizes the
    /// Dock and Finder ask for most, up to 1024 pixels; the system scales
    /// it for the others (#87).
    @Test
    func theIconReachesEveryLargeSize() throws {
        let icon = try #require(NSImage(named: "AppIcon"))
        let widths = Set(icon.representations.map(\.pixelsWide))
        for width in [32, 64, 256, 512, 1024] {
            #expect(widths.contains(width), "\(width) pixels")
        }
    }

    /// The icon as the system draws it, and the flat icon Xcode made from
    /// it for macOS 14 and 15, as PNGs for the pull request (#87).
    @Test
    func theIconIsDrawnForTheSystemAndForEarlierSystems() throws {
        let system = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let icns = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
        let drawn = [
            "app-icon-system": try Self.png(of: system),
            "app-icon-legacy": try Self.png(of: try #require(NSImage(contentsOf: icns)))
        ]
        try FileManager.default.createDirectory(at: Screenshots.directory, withIntermediateDirectories: true)
        for (name, data) in drawn {
            try data.write(to: Screenshots.directory.appendingPathComponent("\(name).png"))
        }
        #expect(drawn.values.allSatisfy { !$0.isEmpty })
    }

    private static func png(of image: NSImage) throws -> Data {
        let size = 512
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
