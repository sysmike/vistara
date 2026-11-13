import CoreGraphics
import Foundation
import Observation
import RDPKit
import RDPKitUI
import VistaraCore

/// Everything one session window shows, and the session behind it.
@MainActor
@Observable
final class SessionModel {
    enum Phase: Equatable {
        case connecting
        case connected
        /// The network went away; the session is being brought back.
        case reconnecting(Reconnection)
        case disconnected(RDPDisconnectReason)

        var isReconnecting: Bool {
            if case .reconnecting = self { return true }
            return false
        }
    }

    private(set) var target: SessionTarget
    /// Opens the editor for this session's saved connection, if it has one.
    @ObservationIgnored var onEditConnection: (() -> Void)?
    /// Saves fresh bookmarks of moved shared folders to the saved connection.
    @ObservationIgnored var onRenewedSharedFolders: (([SharedFolderAccess.Renewal]) -> Void)?
    /// Set here and in SessionModel+Reconnection.swift only.
    var phase: Phase
    /// A certificate waiting for the user's decision.
    private(set) var pendingCertificate: RDPCertificate?
    /// The desktop of the current or last session.
    private(set) var framebuffer: RDPFramebuffer?

    /// Whether the session window is in full screen. Set by the window.
    var isFullScreen = false
    /// The remote monitors when the session spans several displays; empty
    /// otherwise. Set by the window. See SessionModel+Displays.swift.
    var displayMonitors: [DisplayLayout.Monitor] = []
    /// The monitor layout last asked of the server, so none is sent twice.
    @ObservationIgnored var requestedLayout: [RDPMonitor] = []
    /// Whether anyone can see the session. Set by the window; while false the
    /// server stops sending the screen (docs/DESIGN.md, Session tabs).
    /// The user ended the session; set by disconnect(), read when it ends.
    @ObservationIgnored var endedByUser = false
    @ObservationIgnored var isVisible = true {
        didSet { if isVisible != oldValue, isConnected { send([.displayUpdates(isVisible)]) } }
    }

    /// The last session ended because the connection accepts only trusted
    /// certificates and this one was not.
    private(set) var refusedCertificateByPolicy = false

    /// The scale the current session was connected with, in percent.
    private(set) var connectedScale: UInt16 = 100
    /// Whether the session window is the key window. Set by the window.
    @ObservationIgnored var isInFront: () -> Bool = { false }
    @ObservationIgnored private var clipboard: ClipboardBridge?
    /// The shared folders, open while a session runs.
    @ObservationIgnored private var folderAccess: SharedFolderAccess?

    /// The last picture of a lost session, shown dimmed while reconnecting.
    var lastFrame: CGImage?
    /// Reconnecting ran out of attempts; the window says so.
    var didGiveUpReconnecting = false
    @ObservationIgnored var reconnectionPolicy = ReconnectionPolicy()
    @ObservationIgnored var reconnectWait: Task<Void, Never>?
    @ObservationIgnored var reconnectionTriggers: ReconnectionTriggers?

    /// The desktop size that fills the session window now. Set by the window.
    @ObservationIgnored var windowDesktopSize: (() -> DesktopSize?)?

    /// Set while the credentials sheet should be shown.
    private(set) var pendingCredentials: CredentialsRequest?

    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let trustStore: CertificateTrustStore
    @ObservationIgnored private var session: RDPSession?
    @ObservationIgnored private var certificateAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var credentialsAnswer: CheckedContinuation<RDPCredentials?, Never>?
    /// What the sheet returned for the attempt in progress. Held only until
    /// that attempt has connected or failed; a password is never kept longer.
    @ObservationIgnored private var enteredCredentials: CredentialsAnswer?
    /// The last attempt was refused: ask again instead of using what is saved.
    @ObservationIgnored private var wasRefused = false
    /// The user asked to sign in with another account: ask once, without
    /// saying that anything was wrong.
    @ObservationIgnored private var asksForAnotherAccount = false

    init(
        target: SessionTarget,
        credentialStore: any CredentialStore,
        trustStore: CertificateTrustStore,
        phase: Phase = .connecting
    ) {
        self.target = target
        self.credentialStore = credentialStore
        self.trustStore = trustStore
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

    /// Shares the clipboard with a connected session, if the connection allows it.
    private func startClipboard(for session: RDPSession) {
        guard target.sharesClipboard, clipboard == nil else { return }
        let bridge = ClipboardBridge(
            send: { [weak session] events in session?.send(events) },
            isInFront: { [weak self] in self?.isInFront() ?? false }
        )
        bridge.start(remote: session.remoteClipboard)
        clipboard = bridge
    }

    /// Takes new settings for the next connection.
    func retarget(_ target: SessionTarget) {
        self.target = target
    }

    /// Starts a session unless one is running.
    func connect() {
        guard session == nil else { return }
        endedByUser = false
        // A reconnection attempt keeps showing the reconnecting state.
        if !phase.isReconnecting {
            phase = .connecting
            didGiveUpReconnecting = false
        }

        let delegate = RDPSessionDelegate(
            credentials: { [weak self] _ in await self?.credentials() },
            certificateDecision: { [weak self] certificate in
                await self?.decide(certificate) ?? false
            }
        )
        let desktop = startingDesktopSize()
        connectedScale = desktop.scalePercent
        refusedCertificateByPolicy = false
        var configuration = target.configuration(desktop: desktop)
        applyDisplays(to: &configuration)
        let access = SharedFolderAccess(target.sharedFolders)
        folderAccess = access
        configuration.sharedFolders = access.folders
        keepRenewedFolders(access.renewed)
        // The Mac's input source, as the layout a new remote session starts with.
        configuration.keyboard = MacKeyboardLayout.current
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

    /// The size to connect with: the fixed size if the connection has one,
    /// otherwise what fills the window, so the first picture already fits.
    func startingDesktopSize() -> DesktopSize {
        let window = windowDesktopSize?() ?? DesktopSize(width: 1280, height: 800, scalePercent: 100)
        guard target.resolutionMode == .fixed else { return window }
        return DesktopSize(
            width: UInt16(clamping: min(max(target.fixedWidth, 200), 8192)),
            height: UInt16(clamping: min(max(target.fixedHeight, 200), 8192)),
            scalePercent: window.scalePercent
        )
    }

    /// Ends the session, or cancels connecting. The window shows the result.
    func disconnect() {
        if phase.isReconnecting {
            cancelReconnecting()
            return
        }
        // A loss that was already on its way does not start reconnecting.
        endedByUser = true
        session?.disconnect()
    }

    /// Connects again after the session ended; while reconnecting, tries now.
    func reconnect() {
        if phase.isReconnecting {
            reconnectNow()
            return
        }
        guard !isLive else { return }
        connect()
    }

    /// Drops the attempt in progress at once, without waiting for it to end.
    func abandonAttempt() {
        if let session {
            self.session = nil
            session.disconnect()
            folderAccess?.stop()
            folderAccess = nil
            enteredCredentials = nil
        }
        answerCertificate(trust: false)
        answerCredentials(nil)
    }

    /// Connects again and asks for credentials, even when some are saved.
    func reconnectWithAnotherAccount() {
        guard !isLive else { return }
        asksForAnotherAccount = true
        connect()
    }

    /// Answers the certificate question, if one is open.
    func answerCertificate(_ decision: CertificateDecision) {
        let answer = certificateAnswer
        let certificate = pendingCertificate
        certificateAnswer = nil
        pendingCertificate = nil
        guard let answer else { return }
        if decision == .alwaysTrust, let certificate {
            // If this cannot be saved, the certificate is trusted this once
            // and the next connection asks again.
            try? trustStore.add(host: certificate.host, port: certificate.port, fingerprint: certificate.fingerprint)
        }
        answer.resume(returning: decision != .cancel)
    }

    func answerCertificate(trust: Bool) {
        answerCertificate(trust ? .trustOnce : .cancel)
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
            if !phase.isReconnecting { phase = .connecting }
        case .connected:
            endReconnection()
            startClipboard(for: source)
            keepOrForgetEnteredCredentials()
            wasRefused = false
            phase = .connected
            // A session that connects where nobody can see it.
            if !isVisible { send([.displayUpdates(false)]) }
        case .disconnected(let reason):
            let wasConnected = phase == .connected
            clipboard?.stop()
            clipboard = nil
            folderAccess?.stop()
            folderAccess = nil
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
                if !continueReconnecting(after: reason, wasConnected: wasConnected) {
                    phase = .disconnected(reason)
                }
            }
        }
    }
}

// MARK: Questions for the user

extension SessionModel {
    /// The credentials for a connection attempt: what is saved, or else what
    /// the user enters in the sheet. Returns nil when the user cancels or the
    /// session is disconnected meanwhile.
    private func credentials() async -> RDPCredentials? {
        let saved = try? credentialStore.credentials(for: target.credentialKey)
        let mustAsk = wasRefused || asksForAnotherAccount
        asksForAnotherAccount = false
        if !mustAsk, let saved {
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

    /// Decides about a certificate macOS does not trust on its own. One the
    /// user chose to always trust for this computer passes; anything else is
    /// shown, a changed certificate as a warning. Returns false at once when
    /// the session is disconnected meanwhile.
    private func decide(_ presented: RDPCertificate) async -> Bool {
        var shown = presented
        let known = trustStore.trust(forHost: shown.host, port: shown.port, fingerprint: shown.fingerprint)
        // "Require a Trusted Certificate": nothing new is ever asked about.
        if target.certificatePolicy == .requireTrusted, known != .trusted {
            refusedCertificateByPolicy = true
            return false
        }
        switch known {
        case .trusted:
            return true
        case .unknown:
            shown.previousFingerprint = nil
        case .changed(let previousFingerprint):
            shown.previousFingerprint = previousFingerprint
        }
        let certificate = shown
        return await withTaskCancellationHandler {
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

extension SessionModel {
    /// Uses the fresh bookmarks of moved shared folders for the rest of this
    /// window's sessions, and passes them on to be saved (#79).
    func keepRenewedFolders(_ renewals: [SharedFolderAccess.Renewal]) {
        guard !renewals.isEmpty else { return }
        var target = target
        target.sharedFolders = target.sharedFolders.map { folder in
            renewals.first { $0.old == folder }?.new ?? folder
        }
        self.target = target
        onRenewedSharedFolders?(renewals)
    }
}
