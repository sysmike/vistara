import Foundation
import Observation
import RDPKit
import VistaraCore

/// The computer a session window connects to.
struct SessionTarget: Equatable, Sendable {
    /// Shown as the window title.
    var name: String
    var host: String
    var port: UInt16
    /// Suggested in the credentials sheet when nothing is saved.
    var username = ""
    var domain: String?

    /// Identifies this computer's item in the credential store. A saved
    /// connection will use its own identifier here (issue #21).
    var credentialKey: String {
        "\(host.lowercased()):\(port)"
    }
}

/// What the credentials sheet starts with. Never a password.
struct CredentialsRequest: Equatable {
    var username: String
    var domain: String
    var remember: Bool
    /// Why the sheet is back, after credentials were refused.
    var message: String?
}

/// What the user entered in the credentials sheet.
struct CredentialsAnswer {
    var username: String
    var domain: String
    var password: String
    var remember: Bool

    var domainOrNil: String? {
        domain.isEmpty ? nil : domain
    }
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

    /// Set while the credentials sheet should be shown.
    private(set) var pendingCredentials: CredentialsRequest?

    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private var session: RDPSession?
    @ObservationIgnored private var certificateAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var credentialsAnswer: CheckedContinuation<RDPCredentials?, Never>?
    /// What the sheet returned for the attempt in progress. Held only until
    /// that attempt has connected or failed; a password is never kept longer.
    @ObservationIgnored private var enteredCredentials: CredentialsAnswer?
    /// The last attempt was refused: ask again instead of using what is saved.
    @ObservationIgnored private var wasRefused = false

    init(target: SessionTarget, credentialStore: any CredentialStore, phase: Phase = .connecting) {
        self.target = target
        self.credentialStore = credentialStore
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

        let delegate = RDPSessionDelegate(
            credentials: { [weak self] _ in await self?.credentials() },
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

    /// Answers the credentials question, if one is open. Nil cancels the
    /// connection.
    func answerCredentials(_ answer: CredentialsAnswer?) {
        let continuation = credentialsAnswer
        credentialsAnswer = nil
        pendingCredentials = nil
        guard let continuation else { return }
        enteredCredentials = answer
        continuation.resume(
            returning: answer.map {
                RDPCredentials(username: $0.username, domain: $0.domainOrNil, password: $0.password)
            }
        )
    }

    private func apply(_ state: RDPSessionState, from source: RDPSession) {
        guard source === session else { return }
        switch state {
        case .connecting, .awaitingCredentials, .awaitingCertificateDecision:
            phase = .connecting
        case .connected:
            keepOrForgetEnteredCredentials()
            wasRefused = false
            phase = .connected
        case .disconnected(let reason):
            session = nil
            enteredCredentials = nil
            answerCertificate(trust: false)
            answerCredentials(nil)
            if reason == .authenticationFailed {
                // Back to the credentials sheet, with the reason.
                wasRefused = true
                connect()
            } else {
                wasRefused = false
                phase = .disconnected(reason)
            }
        }
    }

    /// The credentials for a connection attempt: what is saved, or else what
    /// the user enters in the sheet. Returns nil when the user cancels or the
    /// session is disconnected meanwhile.
    private func credentials() async -> RDPCredentials? {
        let saved = try? credentialStore.credentials(for: target.credentialKey)
        if !wasRefused, let saved {
            return RDPCredentials(username: saved.username, domain: saved.domain, password: saved.password)
        }
        let request = CredentialsRequest(
            username: saved?.username ?? target.username,
            domain: saved?.domain ?? target.domain ?? "",
            remember: saved != nil,
            message: wasRefused ? "The user name or password is incorrect." : nil
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                answerCredentials(nil)
                credentialsAnswer = continuation
                pendingCredentials = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerCredentials(nil)
            }
        }
    }

    /// The server accepted what the user entered: save it if asked to, and
    /// otherwise make sure nothing older stays saved.
    private func keepOrForgetEnteredCredentials() {
        guard let entered = enteredCredentials else { return }
        enteredCredentials = nil
        if entered.remember {
            let credentials = StoredCredentials(
                username: entered.username, domain: entered.domainOrNil, password: entered.password
            )
            try? credentialStore.save(credentials, for: target.credentialKey, label: "Vistara (\(target.name))")
        } else {
            try? credentialStore.remove(for: target.credentialKey)
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
