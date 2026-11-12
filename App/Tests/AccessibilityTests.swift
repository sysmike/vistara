import AppKit
import Foundation
import RDPKit
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// Contrast of the text colors Vistara uses, measured from the system's
/// actual color values in each appearance (WCAG 2 formula). Increase
/// Contrast is a system setting these values cannot be resolved for, so it is
/// not measured here.
@Suite
@MainActor
struct ContrastTests {
    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// `color` resolved in `appearance`, in sRGB.
    static func resolve(_ color: NSColor, in appearance: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return resolved
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast of `text` drawn on `background`, with the text's own
    /// transparency blended in first.
    static func contrast(_ text: NSColor, on background: NSColor, in appearance: NSAppearance.Name) -> Double? {
        guard let text = resolve(text, in: appearance), let background = resolve(background, in: appearance) else {
            return nil
        }
        let alpha = Double(text.alphaComponent)
        func blend(_ front: CGFloat, _ back: CGFloat) -> Double {
            alpha * Double(front) + (1 - alpha) * Double(back)
        }
        let front = luminance(
            red: blend(text.redComponent, background.redComponent),
            green: blend(text.greenComponent, background.greenComponent),
            blue: blend(text.blueComponent, background.blueComponent)
        )
        let back = luminance(
            red: Double(background.redComponent), green: Double(background.greenComponent),
            blue: Double(background.blueComponent)
        )
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    static let backgrounds: [(String, NSColor)] = [
        ("window", .windowBackgroundColor), ("control", .controlBackgroundColor)
    ]

    private func report(_ name: String, _ text: NSColor) -> [NSAppearance.Name: Double] {
        var lowest: [NSAppearance.Name: Double] = [:]
        for appearance in Self.appearances {
            for (backgroundName, background) in Self.backgrounds {
                guard let ratio = Self.contrast(text, on: background, in: appearance) else { continue }
                print(String(format: "Contrast %@ on %@, %@: %.2f:1", name, backgroundName, appearance.rawValue, ratio))
                lowest[appearance] = min(lowest[appearance] ?? .infinity, ratio)
            }
        }
        return lowest
    }

    @Test
    func primaryTextIsAtLeast4Point5To1Everywhere() {
        let lowest = report("label", .labelColor)
        #expect(lowest.count == Self.appearances.count)
        for (appearance, ratio) in lowest {
            #expect(ratio >= 4.5, "\(appearance.rawValue): \(ratio)")
        }
    }

    /// The system's secondary text color, kept for supplementary text such as
    /// footnotes and paths, as System Settings does. It passes 4.5:1 in dark
    /// mode and stays near 3.8:1 in light mode, a gap recorded on issue #31;
    /// anything needed to act uses the label color instead.
    @Test
    func secondaryTextIsMeasured() {
        let lowest = report("secondaryLabel", .secondaryLabelColor)
        #expect((lowest[.darkAqua] ?? 0) >= 4.5)
        #expect((lowest[.aqua] ?? 0) >= 3.5)
    }

    /// Red is used only for icons, never for words: as text it would fall
    /// below 4.5:1 on a light form.
    @Test
    func redIsAnIconColorOnly() {
        let lowest = report("systemRed", .systemRed)
        #expect((lowest[.aqua] ?? 0) < 4.5)
    }
}

@Suite
struct SessionAnnouncementTests {
    @Test
    func eachNewStateIsAnnouncedOnce() {
        let lost = RDPDisconnectReason.connectionLost(RDPFailure(kind: .networkLost))
        let first = Reconnection(lost: lost)
        var trying = first
        trying.isTrying = true
        // Another attempt is the same state: nothing new to say.
        let name = "Build Server"
        let kind = SessionAnnouncement.kind
        #expect(kind(.reconnecting(first)) == kind(.reconnecting(trying)))
        #expect(SessionAnnouncement.text(for: .connecting, name: name, message: nil) == nil)
        #expect(SessionAnnouncement.text(for: .connected, name: name, message: nil) == "Connected to “Build Server”")
        #expect(SessionAnnouncement.text(for: .reconnecting(first), name: name, message: nil)?
            .contains("Reconnecting") == true)
        let message = DisconnectMessage(reason: lost, name: name, host: "build01")
        #expect(SessionAnnouncement.text(for: .disconnected(lost), name: name, message: message) == message.title)
    }
}
