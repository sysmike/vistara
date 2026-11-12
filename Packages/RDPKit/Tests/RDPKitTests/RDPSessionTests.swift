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

    @Test func unreachableServerIsAConnectionFailure() async {
        let delegate = RDPSessionDelegate(
            credentials: { _ in RDPCredentials(username: "nobody", password: "nothing") },
            certificateDecision: { _ in true }
        )
        let states = await runToEnd(RDPSession(configuration: nobodyHome, delegate: delegate))

        #expect(states.map(\.kind) == ["connecting", "awaitingCredentials", "connecting", "disconnected"])
        guard case .disconnected(.connectionFailed(let code)) = states.last else {
            Issue.record("expected a connection failure, got \(String(describing: states.last))")
            return
        }
        #expect(!code.isEmpty)
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
}
