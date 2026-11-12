import AppKit
import Foundation
import RDPKit
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// Walks the accessibility tree that VoiceOver reads and finds the controls
/// in it, with their labels and sizes.
@MainActor
enum AccessibilityAudit {
    struct Control: CustomStringConvertible {
        let role: String
        let label: String
        let size: CGSize

        var description: String {
            "\(role) “\(label)” \(Int(size.width))×\(Int(size.height))"
        }
    }

    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .popUpButton, .menuButton, .textField, .radioButton, .comboBox, .slider,
        .incrementor, .disclosureTriangle
    ]

    static func controls(in view: some View, size: NSSize) -> [Control] {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [Control] = []
        collect(host, into: &found, depth: 0)
        window.contentView = nil
        return found
    }

    private static func collect(_ element: any NSAccessibilityProtocol, into found: inout [Control], depth: Int) {
        guard depth < 60 else { return }
        // Most of the protocol is optional, hence the ?() calls.
        if let role = element.accessibilityRole?() ?? nil, controlRoles.contains(role),
            element.isAccessibilityElement?() ?? true {
            let label = [element.accessibilityLabel?() ?? nil, element.accessibilityTitle?() ?? nil]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            found.append(Control(role: role.rawValue, label: label, size: element.accessibilityFrame().size))
        }
        for child in (element.accessibilityChildren?() ?? nil) ?? [] {
            if let child = child as? any NSAccessibilityProtocol { collect(child, into: &found, depth: depth + 1) }
        }
    }
}

/// Every control in every main view has a label VoiceOver can read.
@Suite(.serialized)
@MainActor
struct AccessibilityLabelTests {
    private static let certificate = RDPCertificate(
        host: "build01.example.com", port: 3389, commonName: "build01.example.com",
        subject: "CN = build01.example.com", issuer: "CN = build01.example.com",
        fingerprint: "3f:9a:11:c4:5e:7b:02:d8:66:1a:90:ef:4c:33:b7:25:8d:e1:0f:72:a4:5b:c9:16:e8:30:7d:94:2b:6f:ac:51",
        validFrom: Date(timeIntervalSince1970: 1_790_000_000), validUntil: Date(timeIntervalSince1970: 1_990_000_000)
    )

    /// Audits one view: it has at least `expected` controls, all labelled.
    private func audit(_ name: String, _ view: some View, size: NSSize, expected: Int) {
        let controls = AccessibilityAudit.controls(in: view, size: size)
        print("Accessibility audit, \(name): \(controls.count) controls")
        controls.forEach { print("  \($0)") }
        #expect(controls.count >= expected, "\(name): found \(controls.count) controls")
        let unlabelled = controls.filter { $0.label.isEmpty }
        #expect(unlabelled.isEmpty, "\(name): \(unlabelled)")
    }

    @Test
    func theConnectionsWindow() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        audit("connections", ConnectionsView(model: model) { _ in }, size: NSSize(width: 780, height: 420), expected: 0)
    }

    @Test
    func theConnectionEditor() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-a11y-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Transfer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var draft = ConnectionDraft(SampleLibrary.library.connections[0])
        draft.share([try SharedFolderAccess.sharedFolder(for: folder)])
        let editor = ConnectionEditor(draft: draft, folders: [SampleLibrary.lab]) { _ in }
        audit("editor", editor, size: NSSize(width: 480, height: 1150), expected: 15)
    }

    @Test
    func theSheetsAndSessionStates() {
        let request = CredentialsRequest(username: "alice", domain: "", remember: true)
        audit("credentials", CredentialsSheet(name: "Build Server", request: request) { _ in },
              size: NSSize(width: 420, height: 230), expected: 5)
        audit("certificate", CertificateSheet(certificate: Self.certificate) { _ in },
              size: NSSize(width: 520, height: 420), expected: 3)
        audit("connecting", ConnectingView(name: "Build Server") {}, size: NSSize(width: 480, height: 300), expected: 1)
        audit("reconnecting", ReconnectingView(name: "Build Server", lastFrame: nil, isTrying: false, cancel: {},
                                               reconnectNow: {}),
              size: NSSize(width: 480, height: 300), expected: 2)
        let message = DisconnectMessage(
            reason: .connectionFailed(RDPFailure(kind: .hostNotFound, name: "ERRCONNECT_DNS_NAME_NOT_FOUND")),
            name: "Build Server", host: "build01.example.com", canEditConnection: true
        )
        audit("disconnected", DisconnectedView(message: message, showsDetails: true) { _ in },
              size: NSSize(width: 600, height: 420), expected: 3)
    }

    @Test
    func theSettingsPanes() {
        audit("general", GeneralSettingsView(), size: NSSize(width: 520, height: 560), expected: 8)
        audit("keyboard", KeyboardSettingsView(), size: NSSize(width: 520, height: 300), expected: 2)
        audit("security", SecuritySettingsView(trustStore: temporaryTrustStore()),
              size: NSSize(width: 560, height: 360), expected: 1)
    }

    @Test
    func iconOnlyButtonsAreLargeEnoughToAimAt() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-a11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shared = try SharedFolderAccess.sharedFolder(for: folder)
        let row = SharedFolderRow(folder: .constant(shared)) {}
        let form = Form { row }.formStyle(.grouped)
        let controls = AccessibilityAudit.controls(in: form, size: NSSize(width: 480, height: 120))
        let stop = try #require(controls.first { $0.label.hasPrefix("Stop sharing") })
        #expect(stop.size.width >= 20 && stop.size.height >= 20, "\(stop)")
    }
}

/// Contrast of the text colors Vistara uses, measured from the system's
/// actual color values in each appearance (WCAG 2 formula).
@Suite
@MainActor
struct ContrastTests {
    static let appearances: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
    ]

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

    /// The system's secondary text color, used for explanations as the design
    /// asks (semantic colors). It is reported here; with Increase Contrast it
    /// must reach 4.5:1.
    @Test
    func secondaryTextReaches4Point5To1WithIncreaseContrast() {
        let lowest = report("secondaryLabel", .secondaryLabelColor)
        for appearance in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            #expect((lowest[appearance] ?? 0) >= 4.5, "\(appearance.rawValue): \(lowest[appearance] ?? 0)")
        }
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
