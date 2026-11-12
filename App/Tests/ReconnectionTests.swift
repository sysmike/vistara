import Foundation
import RDPKit
import Testing
import VistaraCore
@testable import Vistara

/// When a lost session comes back by itself, and what the window says.
@Suite
struct ReconnectionPolicyTests {
    private func lost(_ kind: RDPFailure.Kind) -> RDPDisconnectReason {
        .connectionLost(RDPFailure(kind: kind))
    }

    private func failed(_ kind: RDPFailure.Kind) -> RDPDisconnectReason {
        .connectionFailed(RDPFailure(kind: kind))
    }

    @Test
    func onlyANetworkThatWentAwayReconnects() {
        for kind in RDPFailure.Kind.allCases {
            #expect(ReconnectionPolicy.reconnects(after: lost(kind)) == (kind == .networkLost), "\(kind)")
        }
        for reason in [RDPDisconnectReason.userRequested, .credentialsCancelled, .certificateRejected,
                       .authenticationFailed, failed(.networkLost)] {
            #expect(!ReconnectionPolicy.reconnects(after: reason), "\(reason)")
        }
    }

    @Test
    func attemptsGoOnOnlyWhileTheComputerCannotBeReached() {
        for kind in [RDPFailure.Kind.hostNotFound, .unreachable, .notResponding, .refused, .starting, .cannotConnect] {
            #expect(ReconnectionPolicy.retries(after: failed(kind)), "\(kind)")
        }
        #expect(ReconnectionPolicy.retries(after: lost(.networkLost)))
        for reason in [RDPDisconnectReason.authenticationFailed, .certificateRejected, .credentialsCancelled,
                       failed(.passwordExpired), failed(.accountRestricted), failed(.licensing),
                       lost(.endedByServer), lost(.replacedByAnotherConnection)] {
            #expect(!ReconnectionPolicy.retries(after: reason), "\(reason)")
        }
    }

    @Test
    func theDefaultScheduleTriesForAboutAMinute() {
        let total = ReconnectionPolicy().delays.reduce(Duration.zero, +)
        #expect(total >= .seconds(45) && total <= .seconds(90))
    }

    @Test
    func afterGivingUpTheWindowSaysVistaraTried() {
        let reason = lost(.networkLost)
        let plain = DisconnectMessage(reason: reason, name: "Build Server", host: "build01")
        let tried = DisconnectMessage(reason: reason, name: "Build Server", host: "build01", gaveUpReconnecting: true)
        #expect(plain.title == tried.title)
        #expect(tried.explanation?.contains("couldn’t reconnect") == true)
        #expect(plain.explanation?.contains("couldn’t reconnect") == false)
        #expect(tried.action == .connect("Reconnect"))
    }
}

/// Against the test server, which cuts the connection when F24 is pressed.
@Suite(.serialized, .enabled(if: TestServer.isFreeRDPTestServer), .timeLimit(.minutes(2)))
@MainActor
struct ReconnectionFlowTests {
    static let dropKey = RDPInputEvent.key(RDPScancode(0x76), isDown: true)
    static let quickly = ReconnectionPolicy(delays: [.milliseconds(200), .milliseconds(200), .milliseconds(200)])

    private func connectedModel(
        _ change: (inout SessionTarget) -> Void = { _ in }, trust: CertificateDecision = .alwaysTrust
    ) async throws -> SessionModel {
        let server = try #require(TestServer.current)
        var target = server.address
        change(&target)
        let model = SessionModel(target: target, credentialStore: try server.storeWithCredentials())
        model.reconnectionPolicy = Self.quickly
        model.connect()
        await waitUntil("the certificate question is open") { model.pendingCertificate != nil }
        model.answerCertificate(trust)
        await waitUntil("the session is connected") { model.phase == .connected }
        return model
    }

    private func end(_ model: SessionModel) async {
        model.disconnect()
        if model.phase.isReconnecting { model.cancelReconnecting() }
        await waitUntil("the session has ended") { !model.isLive }
    }

    @Test
    func aDroppedSessionComesBackByItself() async throws {
        let model = try await connectedModel()
        model.send([Self.dropKey])
        await waitUntil("reconnecting has started") { model.phase.isReconnecting }
        #expect(model.lastFrame != nil)
        // Trusted always: no question on the way back.
        await waitUntil("the session is connected again") {
            #expect(model.pendingCertificate == nil)
            return model.phase == .connected
        }
        #expect(model.lastFrame == nil)
        await end(model)
    }

    @Test
    func theCertificateIsCheckedAgainOnEveryReconnect() async throws {
        let model = try await connectedModel(trust: .trustOnce)
        model.send([Self.dropKey])
        await waitUntil("the certificate question is open again") { model.pendingCertificate != nil }
        #expect(model.phase.isReconnecting)
        model.answerCertificate(.trustOnce)
        await waitUntil("the session is connected again") { model.phase == .connected }
        await end(model)
    }

    @Test
    func withReconnectingTurnedOffTheWindowSaysTheConnectionWasLost() async throws {
        let model = try await connectedModel { $0.reconnectsAutomatically = false }
        model.send([Self.dropKey])
        await waitUntil("the session has ended") { !model.isLive }
        guard case .disconnected(.connectionLost(let failure)) = model.phase else {
            Issue.record("Expected a lost connection, got \(model.phase)")
            return
        }
        #expect(failure.kind == .networkLost)
        #expect(!model.didGiveUpReconnecting)
    }

    @Test
    func cancelStopsReconnecting() async throws {
        let model = try await connectedModel()
        model.reconnectionPolicy = ReconnectionPolicy(delays: [.seconds(60)])
        model.send([Self.dropKey])
        await waitUntil("reconnecting has started") { model.phase.isReconnecting }
        model.cancelReconnecting()
        guard case .disconnected(.connectionLost) = model.phase else {
            Issue.record("Expected the lost connection, got \(model.phase)")
            return
        }
        #expect(!model.didGiveUpReconnecting)
        #expect(model.reconnectWait == nil)
    }

    @Test
    func reconnectingGivesUpWhenTheComputerStaysAway() async throws {
        let model = try await connectedModel()
        model.send([Self.dropKey])
        await waitUntil("reconnecting has started") { model.phase.isReconnecting }
        // From now on nothing answers.
        var away = model.target
        away.host = "127.0.0.1"
        away.port = 1
        model.retarget(away)
        await waitUntil("reconnecting has given up", within: .seconds(30)) { !model.isLive }
        #expect(model.didGiveUpReconnecting)
        guard case .disconnected(.connectionLost(let failure)) = model.phase else {
            Issue.record("Expected the lost connection, got \(model.phase)")
            return
        }
        #expect(failure.kind == .networkLost)
    }
}
