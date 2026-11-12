import Foundation
import os

/// One RDP connection, from `start()` to the `.disconnected` state.
///
/// Each session runs FreeRDP on its own thread. Nothing here blocks the
/// caller: `start()` and `disconnect()` return at once, and progress arrives
/// on `states`. A session is used once; to reconnect, create another.
public final class RDPSession: Sendable {
    public let configuration: RDPSessionConfiguration

    /// Every state the session goes through, ending with `.disconnected`.
    /// Intended for a single consumer.
    public let states: AsyncStream<RDPSessionState>

    private struct Control {
        var isStarted = false
        var stopRequested = false
        var openQuestion: Task<Void, Never>?
        var abortToken: SessionHandle.AbortToken?
        /// Input accepted while connected, waiting for the session thread.
        var acceptsInput = false
        var pendingInput: [RDPInputEvent] = []
    }

    /// The remote desktop's pixels. Updated from the session thread while
    /// connected; read it from any thread.
    public let framebuffer = RDPFramebuffer()

    private let delegate: RDPSessionDelegate
    private let continuation: AsyncStream<RDPSessionState>.Continuation
    private let control = OSAllocatedUnfairLock(initialState: Control())

    public init(configuration: RDPSessionConfiguration, delegate: RDPSessionDelegate) {
        self.configuration = configuration
        self.delegate = delegate
        let (stream, continuation) = AsyncStream.makeStream(of: RDPSessionState.self)
        self.states = stream
        self.continuation = continuation
    }

    /// Starts connecting. Calling it again does nothing.
    public func start() {
        let shouldStart = control.withLock { control in
            if control.isStarted { return false }
            control.isStarted = true
            return true
        }
        guard shouldStart else { return }

        let thread = Thread { self.run() }
        thread.name = "Vistara RDP session"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the session, whatever it is doing. The final state is
    /// `.disconnected(.userRequested)`.
    public func disconnect() {
        control.withLock { control in
            control.stopRequested = true
            control.openQuestion?.cancel()
            control.abortToken?.abort()
        }
    }

    /// Sends input to the remote computer, in order. Returns at once; the
    /// session thread does the sending. Input is dropped while the session is
    /// not connected.
    public func send(_ events: [RDPInputEvent]) {
        guard !events.isEmpty else { return }
        control.withLock { control in
            guard control.acceptsInput else { return }
            for event in events {
                // Only the latest position or size matters while they pile up.
                if control.pendingInput.last?.isSuperseded(by: event) == true {
                    control.pendingInput.removeLast()
                }
                control.pendingInput.append(event)
            }
            control.abortToken?.wake()
        }
    }

    // MARK: Session thread

    private var isStopRequested: Bool {
        control.withLock { $0.stopRequested }
    }

    private static let log = RDPLogging.logger("Session")

    private func run() {
        let redactor = RDPLogging.redactor
        redactor.add(configuration.host, as: .host)
        redactor.add(configuration.username, as: .user)
        redactor.add(configuration.domain ?? "", as: .user)
        Self.log.notice(
            "Connecting to \(self.configuration.host, privacy: .private):\(self.configuration.port, privacy: .public)"
        )
        continuation.yield(.connecting)
        let reason = connectAndServe()
        let final = isStopRequested ? RDPDisconnectReason.userRequested : reason
        Self.log.notice("Session ended: \(final.logDescription, privacy: .public)")
        continuation.yield(.disconnected(final))
        continuation.finish()
        framebuffer.finish()
    }

    private func connectAndServe() -> RDPDisconnectReason {
        continuation.yield(.awaitingCredentials)
        let configuration = configuration
        let delegate = delegate
        guard let answer = ask({ await delegate.credentials(configuration) }), let credentials = answer else {
            return .credentialsCancelled
        }
        // Kept out of FreeRDP's log lines. The password only while this
        // session can use it.
        let redactor = RDPLogging.redactor
        redactor.add(credentials.username, as: .user)
        redactor.add(credentials.domain ?? "", as: .user)
        redactor.add(credentials.password, as: .secret)
        defer { redactor.remove(credentials.password) }
        guard let handle = SessionHandle() else {
            return .connectionFailed(RDPFailure(kind: .cannotConnect, name: "out of memory"))
        }

        // The token must be gone before the handle is, so both happen here.
        let abortToken = handle.abortToken
        return withExtendedLifetime(handle) {
            control.withLock { control in
                control.abortToken = abortToken
                if control.stopRequested { abortToken.abort() }
            }
            defer { control.withLock { $0.abortToken = nil } }
            return serve(handle, credentials: credentials)
        }
    }

    private func serve(_ handle: SessionHandle, credentials: RDPCredentials) -> RDPDisconnectReason {
        continuation.yield(.connecting)
        let target = SessionHandle.Target(
            host: configuration.host,
            port: configuration.port,
            username: credentials.username,
            domain: credentials.domain,
            password: credentials.password,
            width: configuration.desktopWidth,
            height: configuration.desktopHeight,
            scalePercent: configuration.scalePercent,
            requiresNLA: configuration.requiresNLA
        )
        let delegate = delegate

        let result = handle.connect(to: target) { certificate in
            RDPLogging.redactor.add(certificate.commonName, as: .host)
            // A certificate macOS trusts on its own needs no question.
            if RDPCertificateVerifier.isTrustedBySystem(certificate) { return true }
            self.continuation.yield(.awaitingCertificateDecision(certificate))
            let isAccepted = self.ask { await delegate.certificateDecision(certificate) } ?? false
            if isAccepted { self.continuation.yield(.connecting) }
            return isAccepted
        }
        switch result {
        case .connected: break
        case .certificateRejected: return .certificateRejected
        case .authenticationFailed: return .authenticationFailed
        case .cancelled: return .userRequested
        case .failed(let failure): return .connectionFailed(failure)
        }

        continuation.yield(.connected(width: handle.framebufferWidth, height: handle.framebufferHeight))
        control.withLock { $0.acceptsInput = true }
        defer {
            control.withLock { control in
                control.acceptsInput = false
                control.pendingInput.removeAll()
            }
        }
        while !isStopRequested {
            if !handle.poll(timeoutMilliseconds: 100) {
                let failure = handle.lastFailure(whileConnected: true)
                handle.disconnect()
                return .connectionLost(failure)
            }
            sendPendingInput(to: handle)
            publishChanges(from: handle)
            if let cursor = handle.takeCursor() { framebuffer.setCursor(cursor) }
        }
        handle.disconnect()
        return .userRequested
    }

    /// Sends what `send(_:)` queued. Runs on the session thread.
    private func sendPendingInput(to handle: SessionHandle) {
        let events = control.withLock { control in
            let events = control.pendingInput
            control.pendingInput.removeAll(keepingCapacity: true)
            return events
        }
        for event in events {
            handle.send(event)
        }
    }

    /// Copies what FreeRDP painted during the last poll into `framebuffer`.
    private func publishChanges(from handle: SessionHandle) {
        guard let dirty = handle.takeDirtyRect() else { return }
        let width = handle.framebufferWidth
        let height = handle.framebufferHeight
        _ = handle.withFramebuffer { pixels, stride in
            framebuffer.write(from: pixels, stride: stride, width: width, height: height, dirty: dirty)
        }
    }

    /// Runs an async question and blocks this session thread until it is
    /// answered. Returns nil if the session is disconnected first. Blocking is
    /// acceptable here because the thread belongs to this session alone.
    private func ask<Answer: Sendable>(_ question: @escaping @Sendable () async -> Answer) -> Answer? {
        let answer = OSAllocatedUnfairLock<Answer?>(initialState: nil)
        let answered = DispatchSemaphore(value: 0)
        let task = Task {
            let value = await question()
            answer.withLock { $0 = value }
            answered.signal()
        }
        control.withLock { $0.openQuestion = task }
        defer { control.withLock { $0.openQuestion = nil } }

        // Wake up regularly so that a question that ignores cancellation
        // cannot hold the thread after a disconnect.
        while answered.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if isStopRequested {
                task.cancel()
                return nil
            }
        }
        return isStopRequested ? nil : answer.withLock { $0 }
    }
}
