import Foundation
import Testing

@testable import RDPKit

extension RDPSessionState {
    /// The state without its payload, for comparing sequences.
    var kind: String {
        switch self {
        case .connecting: "connecting"
        case .awaitingCredentials: "awaitingCredentials"
        case .awaitingCertificateDecision: "awaitingCertificateDecision"
        case .connected: "connected"
        case .disconnected: "disconnected"
        }
    }
}

/// Runs a session to its end and returns every state it reported.
/// `onState` may call `disconnect()`.
func runToEnd(
    _ session: RDPSession,
    onState: (RDPSessionState, RDPSession) -> Void = { _, _ in }
) async -> [RDPSessionState] {
    var states: [RDPSessionState] = []
    session.start()
    for await state in session.states {
        states.append(state)
        onState(state, session)
    }
    return states
}

private let nobodyHome = RDPSessionConfiguration(host: "127.0.0.1", port: 1, username: "nobody")

@Suite(.timeLimit(.minutes(1)))
struct RDPSessionTests {
    @Test func declinedCredentialsEndTheSession() async {
        let delegate = RDPSessionDelegate(credentials: { _ in nil }, certificateDecision: { _ in true })
        let states = await runToEnd(RDPSession(configuration: nobodyHome, delegate: delegate))

        #expect(states == [.connecting, .awaitingCredentials, .disconnected(.credentialsCancelled)])
    }

    @Test func disconnectWhileAskingForCredentialsEndsTheSession() async {
        let delegate = RDPSessionDelegate(
            credentials: { _ in
                try? await Task.sleep(for: .seconds(120))
                return nil
            },
            certificateDecision: { _ in true }
        )
        let states = await runToEnd(RDPSession(configuration: nobodyHome, delegate: delegate)) { state, session in
            if state == .awaitingCredentials { session.disconnect() }
        }

        #expect(states == [.connecting, .awaitingCredentials, .disconnected(.userRequested)])
    }

    @Test func aQuestionThatIgnoresCancellationCannotHoldTheSession() async {
        let delegate = RDPSessionDelegate(
            credentials: { _ in
                // Deliberately not cancellable.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
                }
                return RDPCredentials(username: "late", password: "late")
            },
            certificateDecision: { _ in true }
        )
        let started = Date()
        let states = await runToEnd(RDPSession(configuration: nobodyHome, delegate: delegate)) { state, session in
            if state == .awaitingCredentials { session.disconnect() }
        }

        #expect(states.last == .disconnected(.userRequested))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    /// Connects to `configuration` and returns how the attempt failed.
    private func failure(connectingTo configuration: RDPSessionConfiguration) async -> RDPFailure? {
        let delegate = RDPSessionDelegate(
            credentials: { _ in RDPCredentials(username: "nobody", password: "nothing") },
            certificateDecision: { _ in true }
        )
        let states = await runToEnd(RDPSession(configuration: configuration, delegate: delegate))
        #expect(states.map(\.kind) == ["connecting", "awaitingCredentials", "connecting", "disconnected"])
        guard case .disconnected(.connectionFailed(let failure)) = states.last else {
            Issue.record("expected a connection failure, got \(String(describing: states.last))")
            return nil
        }
        return failure
    }

    @Test func aClosedPortIsARefusedConnection() async throws {
        let failure = try #require(await failure(connectingTo: nobodyHome))
        #expect(failure.kind == .refused)
        #expect(failure.osError == ECONNREFUSED)
        #expect(failure.name == "ERRCONNECT_CONNECT_FAILED")
        #expect(failure.technicalDetail.contains("Connection refused"))
    }

    @Test func aNameThatDoesNotExistIsNotFound() async throws {
        // .invalid is reserved and never resolves (RFC 6761).
        let nowhere = RDPSessionConfiguration(host: "vistara-test.invalid", port: 3389, username: "nobody")
        let failure = try #require(await failure(connectingTo: nowhere))
        #expect(failure.kind == .hostNotFound)
        #expect(failure.name.hasPrefix("ERRCONNECT_DNS"))
    }

    @Test func startingTwiceRunsOnce() async {
        let delegate = RDPSessionDelegate(credentials: { _ in nil }, certificateDecision: { _ in true })
        let session = RDPSession(configuration: nobodyHome, delegate: delegate)
        session.start()
        session.start()
        let states = await runToEnd(session)

        #expect(states.map(\.kind) == ["connecting", "awaitingCredentials", "disconnected"])
    }

    @Test func inputForASessionThatIsNotConnectedIsDropped() async {
        let delegate = RDPSessionDelegate(credentials: { _ in nil }, certificateDecision: { _ in true })
        let session = RDPSession(configuration: nobodyHome, delegate: delegate)
        session.send(RDPInputEvent.controlAltDelete)
        _ = await runToEnd(session)
        session.send(RDPInputEvent.controlAltDelete)
    }

    @Test func controlAltDeleteReleasesInReverseOrder() {
        let events = RDPInputEvent.controlAltDelete
        #expect(events.count == 6)
        #expect(events.prefix(3) == [
            .key(.leftControl, isDown: true), .key(.leftAlt, isDown: true), .key(.delete, isDown: true)
        ])
        #expect(Array(events.suffix(3)) == [
            .key(.delete, isDown: false), .key(.leftAlt, isDown: false), .key(.leftControl, isDown: false)
        ])
    }

    @Test func printingCredentialsNeverShowsThePassword() {
        let credentials = RDPCredentials(username: "alice", domain: "CORP", password: "correct horse")
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in ["\(credentials)", String(reflecting: credentials), dumped, "\([credentials])"] {
            #expect(!text.contains("correct horse"))
            #expect(!text.contains("alice"))
        }
    }
}
