import AppKit
import RDPKit
import RDPKitUI
import Testing
@testable import Vistara

@Suite(.serialized)
@MainActor
struct SessionWindowTests {
    private static let nowhere = SessionTarget(
        name: "Nowhere", host: "127.0.0.1", port: 1, username: "nobody", domain: nil
    )

    @Test
    func windowUsesSystemChromeAndTheConnectionName() {
        let model = SessionModel(target: Self.nowhere, password: "", phase: .disconnected(.userRequested))
        let controller = SessionWindowController(model: model)
        let window = controller.window

        #expect(window.title == "Nowhere")
        #expect(window.subtitle == "127.0.0.1")
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.toolbar == nil)
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        window.close()
    }

    @Test
    func connectingAppearsAtOnceAndAFailureIsShownInTheWindow() async {
        let model = SessionModel(target: Self.nowhere, password: "")
        model.connect()
        #expect(model.phase == .connecting)
        #expect(model.isLive)

        await waitUntil("the session has ended") { !model.isLive }
        guard case .disconnected(.connectionFailed) = model.phase else {
            Issue.record("expected a failed connection, got \(model.phase)")
            return
        }
    }

    @Test
    func reconnectDoesNothingWhileASessionIsLive() async {
        let model = SessionModel(target: Self.nowhere, password: "")
        model.connect()
        model.reconnect()
        #expect(model.phase == .connecting)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test(.enabled(if: TestServer.current != nil))
    func connectingCanBeCancelled() async throws {
        let server = try #require(TestServer.current)
        let model = SessionModel(target: server.target, password: server.password)
        model.connect()
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.userRequested))
        #expect(model.pendingCertificate == nil)
    }

    @Test(.enabled(if: TestServer.current != nil))
    func rejectingTheCertificateEndsTheConnection() async throws {
        let server = try #require(TestServer.current)
        let model = SessionModel(target: server.target, password: server.password)
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        #expect(model.pendingCertificate?.fingerprint.isEmpty == false)
        model.answerCertificate(trust: false)
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.certificateRejected))
    }

    @Test(.enabled(if: TestServer.current != nil))
    func aSessionDrawsInItsWindowAndClosingTheWindowDisconnects() async throws {
        let server = try #require(TestServer.current)
        let coordinator = SessionCoordinator()
        let controller = coordinator.open(server.target, password: server.password)
        let model = controller.model
        #expect(coordinator.liveSessionCount == 1)
        // A second request for the same computer reuses the window.
        #expect(coordinator.open(server.target, password: server.password) === controller)

        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }

        var desktop: RDPSessionView?
        await waitUntil("the desktop has been drawn") {
            desktop = controller.window.contentView?.firstDescendant(RDPSessionView.self)
            return (desktop?.drawCount ?? 0) > 0
        }
        let view = try #require(desktop)
        #expect(view.desktopFrame.width > 0)
        #expect(view.accessibilityLabel() == "Remote desktop, Test Server")

        controller.window.close()
        await waitUntil("the session has ended") { !model.isLive }
        #expect(model.phase == .disconnected(.userRequested))
        #expect(coordinator.liveSessionCount == 0)

        // Reconnect brings the session back in a model that has ended.
        model.reconnect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust: true)
        await waitUntil("the session is connected") { model.phase == .connected }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }
}
