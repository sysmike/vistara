import Foundation
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// Every option in the editor reaches the session.
@Suite(.serialized)
@MainActor
struct SessionOptionsTests {
    @Test
    func aNewConnectionStartsSafeAndUseful() {
        let connection = Connection(name: "New", host: "h")
        #expect(connection.port == 3389)
        #expect(connection.resolutionMode == .matchWindow)
        #expect(connection.usesHiDPI)
        #expect(connection.requiresNLA)
        #expect(connection.certificatePolicy == .askOnFirstUse)
        #expect(connection.sharesClipboard)
        #expect(connection.audioMode == .playOnThisMac)
        #expect(connection.reconnectsAutomatically)
    }

    @Test
    func everyOptionOfASavedConnectionReachesTheSession() {
        var connection = Connection(name: "Build Server", host: "build01")
        connection.resolutionMode = .scaleToFit
        connection.usesHiDPI = false
        connection.requiresNLA = false
        connection.certificatePolicy = .requireTrusted
        connection.audioMode = .playOnRemote
        connection.sharesClipboard = false
        connection.reconnectsAutomatically = false

        let target = SessionTarget(connection: connection)
        #expect(target.resolutionMode == .scaleToFit)
        #expect(!target.usesHiDPI)
        #expect(target.certificatePolicy == .requireTrusted)

        let configuration = target.configuration(desktop: DesktopSize(width: 1600, height: 900, scalePercent: 100))
        #expect(configuration.host == "build01")
        #expect(configuration.desktopWidth == 1600)
        #expect(configuration.desktopHeight == 900)
        #expect(configuration.scalePercent == 100)
        #expect(!configuration.requiresNLA)
        #expect(configuration.audio == .remote)
        #expect(!configuration.sharesClipboard)
        #expect(!configuration.reconnectsAutomatically)
    }

    @Test
    func soundSettingsMapOneToOne() {
        var target = SessionTarget(name: "h", host: "h", port: 3389)
        let size = DesktopSize(width: 800, height: 600, scalePercent: 100)
        let expected: [Connection.AudioMode: RDPAudioMode] = [
            .playOnThisMac: .thisMac, .playOnRemote: .remote, .off: .off
        ]
        for (mode, audio) in expected {
            target.audioMode = mode
            #expect(target.configuration(desktop: size).audio == audio, "\(mode)")
        }
    }

    @Test
    func aFixedSizeIsWhatTheSessionAsksFor() {
        var target = SessionTarget(name: "h", host: "h", port: 3389)
        target.resolutionMode = .fixed
        target.fixedWidth = 2560
        target.fixedHeight = 1440
        let model = SessionModel(target: target, credentialStore: InMemoryCredentialStore())
        model.windowDesktopSize = { DesktopSize(width: 1000, height: 700, scalePercent: 200) }
        #expect(model.startingDesktopSize() == DesktopSize(width: 2560, height: 1440, scalePercent: 200))

        target.resolutionMode = .scaleToFit
        model.retarget(target)
        #expect(model.startingDesktopSize() == DesktopSize(width: 1000, height: 700, scalePercent: 200))
    }

    // MARK: Certificate policy

    @Test(.enabled(if: TestServer.current != nil))
    func requiringATrustedCertificateNeverAsksAndConnectsOnceTrusted() async throws {
        let server = try #require(TestServer.current)
        let trustStore = temporaryTrustStore()
        var strict = server.address
        strict.certificatePolicy = .requireTrusted
        let model = SessionModel(
            target: strict, credentialStore: try server.storeWithCredentials(), trustStore: trustStore
        )

        // Unknown: refused without a question, and the window says why.
        var asked = false
        model.connect()
        await waitUntil("the session has ended") {
            asked = asked || model.pendingCertificate != nil
            return !model.isLive
        }
        #expect(!asked)
        #expect(model.phase == .disconnected(.certificateRejected))
        #expect(model.refusedCertificateByPolicy)

        // Trusted once with the usual policy...
        model.retarget(server.address)
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(.alwaysTrust)
        await waitUntil("the session is connected") { model.phase == .connected }
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }

        // ...the strict policy now connects without asking.
        model.retarget(strict)
        asked = false
        model.connect()
        await waitUntil("the session is connected") {
            asked = asked || model.pendingCertificate != nil
            return model.phase == .connected
        }
        #expect(!asked)
        #expect(!model.refusedCertificateByPolicy)
        model.disconnect()
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test
    func aRefusalByPolicySaysSoAndOffersTheEditor() {
        let message = DisconnectMessage(
            reason: .certificateRejected, name: "Build Server", host: "build01", canEditConnection: true,
            refusedByPolicy: true
        )
        #expect(message.title == "“Build Server” presented a certificate this connection doesn’t trust")
        #expect(message.action == .editConnection)
        #expect(message.explanation?.hasSuffix(".") == true)
        #expect(!(message.explanation ?? "").contains("\""))

        // A certificate the user turned down is still "Connection cancelled".
        let declined = DisconnectMessage(reason: .certificateRejected, name: "Build Server", host: "build01")
        #expect(declined.title == "Connection cancelled")
    }
}
