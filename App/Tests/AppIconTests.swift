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

    @Test
    func theIconHasEveryRepresentationTheFinderAndDockUse() throws {
        let icon = try #require(NSImage(named: "AppIcon"))
        let widths = Set(icon.representations.map(\.pixelsWide))
        for width in [16, 32, 64, 128, 256, 512, 1024] {
            #expect(widths.contains(width), "\(width) pixels")
        }
    }
}
