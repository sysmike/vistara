import AppKit
import SwiftUI
import Testing
import VistaraCore
@testable import Vistara

/// The test server started by scripts/run-test-server.sh, if any.
struct TestServer {
    let target: SessionTarget
    let password: String

    static var current: TestServer? {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["VISTARA_TEST_RDP_HOST"], !host.isEmpty,
              let user = environment["VISTARA_TEST_RDP_USER"],
              let password = environment["VISTARA_TEST_RDP_PASSWORD"]
        else { return nil }
        let port = environment["VISTARA_TEST_RDP_PORT"].flatMap { UInt16($0) } ?? 3389
        return TestServer(
            target: SessionTarget(name: "Test Server", host: host, port: port, username: user, domain: nil),
            password: password
        )
    }
}

/// A trust store in a folder of its own that trusts nothing yet.
func temporaryTrustStore() -> CertificateTrustStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vistara-trust-\(UUID().uuidString)", isDirectory: true)
    return CertificateTrustStore(directory: directory)
}

extension SessionModel {
    /// With a trust store that trusts nothing, for tests about other things.
    convenience init(target: SessionTarget, credentialStore: any CredentialStore, phase: Phase = .connecting) {
        self.init(target: target, credentialStore: credentialStore, trustStore: temporaryTrustStore(), phase: phase)
    }
}

extension TestServer {
    /// A store that already holds the server's account, so no sheet appears.
    func storeWithCredentials() throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        let credentials = StoredCredentials(username: target.username, password: password)
        try store.save(credentials, for: target.credentialKey, label: "Test")
        return store
    }

    /// The server's address without an account, as the launcher gives it.
    var address: SessionTarget {
        SessionTarget(name: target.name, host: target.host, port: target.port)
    }
}

/// Waits until the condition holds, and records an issue if it never does.
@MainActor
func waitUntil(
    _ expectation: Comment,
    within timeout: Duration = .seconds(15),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("Timed out waiting until \(expectation)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Renders views to PNG files so a person can look at each state.
@MainActor
enum Screenshots {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-screenshots")

    /// Shows the view in a window of the given content size, renders it, and
    /// returns the file's size in bytes.
    @discardableResult
    static func write(_ view: some View, size: NSSize, name: String, dark: Bool = false) async throws -> Int {
        let content = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        // Controls draw their key-window look only in the key window.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }
        return try write(hosting, name: name)
    }

    @discardableResult
    static func write(_ view: NSView, name: String) throws -> Int {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return data.count
    }
}

extension NSView {
    /// The first view of the given type in this view's hierarchy.
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(type) { return match }
        }
        return nil
    }
}
