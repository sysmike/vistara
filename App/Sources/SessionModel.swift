import Foundation
import Observation
import RDPKit

/// The computer and account a session window connects to.
struct SessionTarget: Equatable, Sendable {
    /// Shown as the window title.
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var domain: String?
}

/// Everything one session window shows, and the session behind it.
@MainActor
@Observable
final class SessionModel {
    enum Phase: Equatable {
        case connecting
        case connected
        case disconnected(RDPDisconnectReason)
    }

    let target: SessionTarget
    private(set) var phase: Phase
    /// A certificate waiting for the user's decision.
    private(set) var pendingCertificate: RDPCertificate?
    /// The desktop of the current or last session.
    private(set) var framebuffer: RDPFramebuffer?

    // Kept in memory for Reconnect until the Keychain store exists (issue #13).
    @ObservationIgnored private let password: String
    @ObservationIgnored private var session: RDPSession?
    @ObservationIgnored private var certificateAnswer: CheckedContinuation<Bool, Never>?

    init(target: SessionTarget, password: String, phase: Phase = .connecting) {
        self.target = target
        self.password = password
        self.phase = phase
    }

    var isLive: Bool {
        if case .disconnected = phase { return false }
        return true
    }

    var isConnected: Bool {
        phase == .connected
    }

    /// Sends keyboard input to the remote computer. Dropped unless connected.
    func send(_ events: [RDPInputEvent]) {
        session?.send(events)
    }

    /// Starts a session unless one is running.
    func connect() {
        guard session == nil else { return }
        phase = .connecting

        let credentials = RDPCredentials(username: target.username, domain: target.domain, password: password)
        let delegate = RDPSessionDelegate(
            credentials: { _ in credentials },
            certificateDecision: { [weak self] certificate in
                await self?.decide(certificate) ?? false
            }
        )
        let configuration = RDPSessionConfiguration(
            host: target.host,
            port: target.port,
            username: target.username,
            domain: target.domain
        )
        let session = RDPSession(configuration: configuration, delegate: delegate)
        self.session = session
        framebuffer = session.framebuffer
        Task { [weak self] in
            for await state in session.states {
                self?.apply(state, from: session)
            }
        }
        session.start()
    }

    /// Ends the session, or cancels connecting. The window shows the result.
    func disconnect() {
        session?.disconnect()
    }

    func reconnect() {
        guard !isLive else { return }
        connect()
    }

    /// Answers the certificate question, if one is open.
    func answerCertificate(trust: Bool) {
        let answer = certificateAnswer
        certificateAnswer = nil
        pendingCertificate = nil
        answer?.resume(returning: trust)
    }

    private func apply(_ state: RDPSessionState, from source: RDPSession) {
        guard source === session else { return }
        switch state {
        case .connecting, .awaitingCredentials, .awaitingCertificateDecision:
            phase = .connecting
        case .connected:
            phase = .connected
        case .disconnected(let reason):
            session = nil
            answerCertificate(trust: false)
            phase = .disconnected(reason)
        }
    }

    /// Shows the certificate and waits for the decision. Returns false at
    /// once when the session is disconnected meanwhile.
    private func decide(_ certificate: RDPCertificate) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                answerCertificate(trust: false)
                certificateAnswer = continuation
                pendingCertificate = certificate
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerCertificate(trust: false)
            }
        }
    }
}
