import AppKit
import Foundation
import RDPKit
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// Renders every state of the session window to a PNG. CI uploads the files
/// so each pull request can be looked at, not only compiled.
@Suite(.serialized)
@MainActor
struct ScreenshotTests {
    private static let target = SessionTarget(
        name: "Build Server", host: "build01.example.com", port: 3389, username: "alice", domain: nil
    )
    private static let windowSize = NSSize(width: 720, height: 450)

    private static let certificate = RDPCertificate(
        host: "build01.example.com",
        port: 3389,
        commonName: "build01.example.com",
        subject: "CN = build01.example.com",
        issuer: "CN = build01.example.com",
        fingerprint: "3f:9a:11:c4:5e:7b:02:d8:66:1a:90:ef:4c:33:b7:25:8d:e1:0f:72:a4:5b:c9:16:e8:30:7d:94:2b:6f:ac:51",
        validFrom: Date(timeIntervalSince1970: 1_790_000_000),
        validUntil: Date(timeIntervalSince1970: 1_990_000_000)
    )

    private static let librarySize = NSSize(width: 780, height: 420)

    @Test(arguments: [
        ("library", NSAppearance.Name.aqua),
        ("library-dark", .darkAqua),
        ("library-contrast", .accessibilityHighContrastAqua),
        ("library-dark-contrast", .accessibilityHighContrastDarkAqua)
    ])
    func library(name: String, appearance: NSAppearance.Name) async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let view = ConnectionsView(model: model) { _ in }
        let bytes = try await Screenshots.write(view, size: Self.librarySize, name: name, appearance: appearance)
        #expect(bytes > 0)
    }

    @Test
    func libraryRecentsAndAFolderBeingNamed() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        model.selection = .recents
        let recents = try await Screenshots.write(
            ConnectionsView(model: model) { _ in }, size: Self.librarySize, name: "library-recents"
        )
        model.addFolder()
        let naming = try await Screenshots.write(
            ConnectionsView(model: model) { _ in }, size: Self.librarySize, name: "library-new-folder"
        )
        #expect(recents > 0 && naming > 0)
    }

    @Test
    func libraryNarrow() async throws {
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        let view = ConnectionsView(model: model) { _ in }
        let size = NSSize(width: 560, height: 320)
        let bytes = try await Screenshots.write(view, size: size, name: "library-narrow")
        #expect(bytes > 0)
    }

    @Test
    func libraryEmptyAndNoResults() async throws {
        let (empty, _) = try await temporaryLibrary()
        let first = try await Screenshots.write(
            ConnectionsView(model: empty) { _ in }, size: Self.librarySize, name: "library-empty"
        )
        let (model, _) = try await temporaryLibrary(SampleLibrary.library)
        model.searchText = "printer"
        let second = try await Screenshots.write(
            ConnectionsView(model: model) { _ in }, size: Self.librarySize, name: "library-no-results"
        )
        #expect(first > 0 && second > 0)
    }

    @Test(arguments: [false, true])
    func editor(dark: Bool) async throws {
        var draft = ConnectionDraft(SampleLibrary.library.connections[0])
        draft.tags = ["prod", "ci"]
        draft.resolutionMode = .fixed
        draft.requiresNLA = false
        let folders = [SampleLibrary.lab, SampleLibrary.office]
        let view = ConnectionEditor(draft: draft, folders: folders, knownTags: ["prod", "test"]) { _ in }
        let name = dark ? "editor-dark" : "editor"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 800), name: name, dark: dark)
        #expect(bytes > 0)
    }

    /// One folder shared read-only, one that can no longer be found.
    @Test(arguments: [false, true])
    func editorWithSharedFolders(dark: Bool) async throws {
        let transfer = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-screenshot-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Transfer", isDirectory: true)
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
        var draft = ConnectionDraft(SampleLibrary.library.connections[0])
        draft.share([
            try SharedFolderAccess.sharedFolder(for: transfer, readOnly: true),
            Connection.SharedFolder(path: "/Volumes/Archive/Projects", bookmark: nil)
        ])
        let view = ConnectionEditor(draft: draft, folders: []) { _ in }
        let name = dark ? "editor-shared-folders-dark" : "editor-shared-folders"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 1150), name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func settingsGeneral(dark: Bool) async throws {
        let name = dark ? "settings-general-dark" : "settings-general"
        let bytes = try await Screenshots.write(
            GeneralSettingsView(), size: NSSize(width: 520, height: 560), name: name, dark: dark
        )
        #expect(bytes > 0)
    }

    @Test
    func settingsKeyboard() async throws {
        let bytes = try await Screenshots.write(
            KeyboardSettingsView(), size: NSSize(width: 520, height: 300), name: "settings-keyboard"
        )
        #expect(bytes > 0)
    }

    /// The lost session's last picture, dimmed, while Vistara reconnects.
    @Test(arguments: [false, true])
    func reconnecting(dark: Bool) async throws {
        let view = ReconnectingView(
            name: "Build Server", lastFrame: Self.sampleDesktop(), isTrying: false, cancel: {}, reconnectNow: {}
        )
        let name = dark ? "reconnecting-dark" : "reconnecting"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 800, height: 500), name: name, dark: dark)
        #expect(bytes > 0)
    }

    /// A desktop of blue with one light window on it.
    private static func sampleDesktop() -> CGImage? {
        let context = CGContext(
            data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        context?.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
        context?.fill(CGRect(x: 160, y: 140, width: 700, height: 480))
        return context?.makeImage()
    }

    @Test
    func editorForANewConnectionWithAProblem() async throws {
        var draft = ConnectionDraft()
        draft.host = "build01:3390"
        let view = ConnectionEditor(draft: draft, folders: [], showsProblems: true) { _ in }
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 640), name: "editor-new")
        #expect(bytes > 0)
    }

    @Test
    func failureWithEditConnection() async throws {
        let message = DisconnectMessage(
            reason: .connectionFailed(RDPFailure(kind: .hostNotFound)), name: "Build Server",
            host: "build01.example.com", canEditConnection: true
        )
        let view = DisconnectedView(message: message) { _ in }
        let bytes = try await Screenshots.write(view, size: Self.windowSize, name: "not-found-edit")
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func connecting(dark: Bool) async throws {
        let model = SessionModel(target: Self.target, credentialStore: InMemoryCredentialStore(), phase: .connecting)
        let name = dark ? "connecting-dark" : "connecting"
        let view = SessionContentView(model: model)
        let bytes = try await Screenshots.write(view, size: Self.windowSize, name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test
    func disconnected() async throws {
        let refused = RDPFailure(
            kind: .refused, code: 0x0002_0006, name: "ERRCONNECT_CONNECT_FAILED",
            description: "A configuration error prevented a connection to be established.", osError: ECONNREFUSED
        )
        let examples: [(name: String, reason: RDPDisconnectReason)] = [
            ("cancelled", .userRequested),
            ("refused", .connectionFailed(refused)),
            ("not-found", .connectionFailed(RDPFailure(kind: .hostNotFound))),
            ("lost", .connectionLost(RDPFailure(kind: .networkLost))),
            ("account-restricted", .connectionFailed(RDPFailure(kind: .accountRestricted))),
            ("certificate-rejected", .certificateRejected)
        ]
        for example in examples {
            let model = SessionModel(
                target: Self.target, credentialStore: InMemoryCredentialStore(), phase: .disconnected(example.reason)
            )
            let view = SessionContentView(model: model)
            let bytes = try await Screenshots.write(view, size: Self.windowSize, name: example.name)
            #expect(bytes > 0)
        }
    }

    @Test
    func detailsOpen() async throws {
        let failure = RDPFailure(
            kind: .refused, code: 0x0002_0006, name: "ERRCONNECT_CONNECT_FAILED",
            description: "A configuration error prevented a connection to be established.", osError: ECONNREFUSED
        )
        let message = DisconnectMessage(
            reason: .connectionFailed(failure), name: "Build Server", host: "build01.example.com"
        )
        let view = DisconnectedView(message: message, showsDetails: true) { _ in }
        let bytes = try await Screenshots.write(view, size: Self.windowSize, name: "refused-details")
        #expect(bytes > 0)
    }

    @Test(arguments: [false, true])
    func credentialsSheet(dark: Bool) async throws {
        let request = CredentialsRequest(username: "", domain: "", remember: false)
        let view = CredentialsSheet(name: "Build Server", request: request) { _ in }
        let size = NSSize(width: 420, height: 230)
        let name = dark ? "credentials-dark" : "credentials"
        let bytes = try await Screenshots.write(view, size: size, name: name, dark: dark)
        #expect(bytes > 0)
    }

    @Test
    func credentialsSheetAfterARefusal() async throws {
        let request = CredentialsRequest(
            username: "alice", domain: "CORP", remember: true, message: "The user name or password is incorrect."
        )
        let view = CredentialsSheet(name: "Build Server", request: request) { _ in }
        let size = NSSize(width: 420, height: 260)
        let bytes = try await Screenshots.write(view, size: size, name: "credentials-refused")
        #expect(bytes > 0)
    }

    @Test
    func changedCertificateAlert() throws {
        var changed = Self.certificate
        changed.previousFingerprint =
            "a1:07:5c:de:42:90:3b:f8:19:c6:7e:05:d3:68:2a:b4:91:0c:e7:36:5f:a8:14:7b:c0:29:e5:83:4d:f1:6a:9e"
        let alert = ChangedCertificateAlert.make(certificate: changed, name: "Build Server")
        alert.layout()
        let content = try #require(alert.window.contentView)
        let bytes = try Screenshots.write(content, name: "certificate-changed")
        #expect(bytes > 0)
    }

    @Test
    func securitySettings() async throws {
        let store = temporaryTrustStore()
        try store.add(host: "build01.example.com", port: 3389, fingerprint: Self.certificate.fingerprint)
        let other = Self.certificate.fingerprint.replacing("3f", with: "77")
        try store.add(host: "10.0.0.5", port: 3390, fingerprint: other)
        let view = SecuritySettingsView(trustStore: store, selection: "build01.example.com:3389")
        let size = NSSize(width: 620, height: 380)
        let bytes = try await Screenshots.write(view, size: size, name: "settings-security")
        #expect(bytes > 0)
    }

    @Test
    func fingerprintLinesNeverSplitAPair() {
        #expect(CertificateSheet.lines(ofFingerprint: "aa:bb:cc:dd:ee", pairsPerLine: 2) == "aa:bb\ncc:dd\nee")
        #expect(CertificateSheet.lines(ofFingerprint: Self.certificate.fingerprint).split(separator: "\n").count == 2)
        #expect(CertificateSheet.lines(ofFingerprint: "").isEmpty)
    }

    @Test(arguments: [false, true])
    func certificateSheet(dark: Bool) async throws {
        let name = dark ? "certificate-dark" : "certificate"
        let view = CertificateSheet(certificate: Self.certificate) { _ in }
        let bytes = try await Screenshots.write(view, size: NSSize(width: 520, height: 280), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
