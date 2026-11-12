internal import CFreeRDP
import Foundation

/// Owns one FreeRDP instance and its context for as long as it lives.
///
/// Not thread-safe: use one handle from one thread. The exception is
/// `abortToken`, which may be used from anywhere.
final class SessionHandle {
    struct Target {
        var host: String
        var port: UInt16 = 3389
        var username: String
        var domain: String?
        var password: String
        var width: UInt32 = 1024
        var height: UInt32 = 768
        var scalePercent: UInt32 = 100
        var requiresNLA = true
    }

    enum ConnectResult: Equatable {
        case connected
        case certificateRejected
        case authenticationFailed
        case cancelled
        case failed(errorName: String)
    }

    /// Lets another thread interrupt a blocking `connect` or end `poll`.
    ///
    /// `@unchecked Sendable` because it carries the session pointer across
    /// threads. That is sound for exactly one use: `vistara_session_abort`
    /// only sets an event inside FreeRDP. The holder must drop the token
    /// before the `SessionHandle` is destroyed; `RDPSession` does so under
    /// its lock.
    struct AbortToken: @unchecked Sendable {
        fileprivate let session: OpaquePointer

        func abort() {
            vistara_session_abort(session)
        }

        /// Ends a running `poll` early. Safe from any thread, like `abort`.
        func wake() {
            vistara_session_wake(session)
        }
    }

    /// Carries the Swift closure through the C callback's context pointer.
    private final class CertificateDecider {
        let decide: (RDPCertificate) -> Bool

        init(_ decide: @escaping (RDPCertificate) -> Bool) {
            self.decide = decide
        }
    }

    private let session: OpaquePointer

    init?() {
        guard let session = vistara_session_create() else { return nil }
        self.session = session
    }

    deinit {
        vistara_session_destroy(session)
    }

    var abortToken: AbortToken { AbortToken(session: session) }

    /// Connects and blocks until connected or failed. `decideCertificate` is
    /// called, on this thread, for a certificate OpenSSL cannot verify.
    /// Without it such a certificate is rejected.
    func connect(to target: Target, decideCertificate: ((RDPCertificate) -> Bool)? = nil) -> ConnectResult {
        // strdup copies so every pointer stays valid for the whole call.
        let hostCopy = strdup(target.host)
        let usernameCopy = strdup(target.username)
        let domain = target.domain.flatMap { strdup($0) }
        let passwordCopy = strdup(target.password)
        defer {
            if let passwordCopy {
                let length = strlen(passwordCopy)
                memset_s(passwordCopy, length, 0, length)
            }
            for pointer in [hostCopy, usernameCopy, domain, passwordCopy] { free(pointer) }
        }
        guard let host = hostCopy, let username = usernameCopy, let password = passwordCopy else {
            return .failed(errorName: "out of memory")
        }

        let decider = decideCertificate.map(CertificateDecider.init)
        var options = vistara_connect_options(
            host: host,
            port: target.port,
            username: username,
            domain: domain,
            password: password,
            width: target.width,
            height: target.height,
            scale_percent: target.scalePercent,
            require_nla: target.requiresNLA,
            decide_certificate: nil,
            decide_certificate_context: nil
        )
        if let decider {
            options.decide_certificate = { context, certificate in
                guard let context else { return false }
                let decider = Unmanaged<CertificateDecider>.fromOpaque(context).takeUnretainedValue()
                return decider.decide(RDPCertificate(certificate.pointee))
            }
            options.decide_certificate_context = Unmanaged.passUnretained(decider).toOpaque()
        }

        return withExtendedLifetime(decider) {
            switch vistara_session_connect(session, &options) {
            case VISTARA_CONNECT_OK: .connected
            case VISTARA_CONNECT_CERTIFICATE_UNTRUSTED: .certificateRejected
            case VISTARA_CONNECT_AUTHENTICATION_FAILED: .authenticationFailed
            case VISTARA_CONNECT_CANCELLED: .cancelled
            default: .failed(errorName: lastErrorName)
            }
        }
    }

    /// FreeRDP's name for the last error, such as `FREERDP_ERROR_CONNECT_FAILED`.
    var lastErrorName: String {
        String(cString: vistara_session_last_error_name(session))
    }

    /// Waits for network activity and processes it. False once disconnected.
    func poll(timeoutMilliseconds: UInt32) -> Bool {
        vistara_session_poll(session, timeoutMilliseconds)
    }

    /// Sends one input event. False when not connected or sending failed.
    @discardableResult
    func send(_ event: RDPInputEvent) -> Bool {
        switch event {
        case .key(let scancode, let isDown):
            vistara_session_send_key(session, scancode.code, scancode.isExtended, isDown)
        case .lockState(let locks):
            vistara_session_send_lock_state(
                session, locks.contains(.capsLock), locks.contains(.numLock), locks.contains(.scrollLock)
            )
        case .pointerMove(let x, let y):
            vistara_session_send_pointer_move(session, x, y)
        case .pointerButton(let button, let isDown, let x, let y):
            vistara_session_send_pointer_button(session, button.rawValue, isDown, x, y)
        case .wheel(let axis, let rotation, let x, let y):
            vistara_session_send_wheel(session, axis == .horizontal, rotation, x, y)
        }
    }

    /// The cursor the server asked for, if it changed since the last call.
    func takeCursor() -> RDPCursor? {
        var cursor = vistara_cursor()
        guard vistara_session_take_cursor(session, &cursor) else { return nil }
        switch cursor.kind {
        case VISTARA_CURSOR_HIDDEN:
            return .hidden
        case VISTARA_CURSOR_IMAGE:
            let width = Int(cursor.width)
            let height = Int(cursor.height)
            guard let pixels = cursor.pixels, width > 0, height > 0 else { return .systemDefault }
            return .image(
                RDPCursorImage(
                    width: width,
                    height: height,
                    hotspotX: Int(cursor.hotspot_x),
                    hotspotY: Int(cursor.hotspot_y),
                    pixels: Data(bytes: pixels, count: width * height * 4)
                )
            )
        default:
            return .systemDefault
        }
    }

    var framebufferWidth: Int { Int(vistara_session_width(session)) }
    var framebufferHeight: Int { Int(vistara_session_height(session)) }

    /// Number of paint cycles that changed the framebuffer since connecting.
    var paintCount: UInt64 { vistara_session_paint_count(session) }

    /// The area painted since the last call, or nil when nothing changed.
    func takeDirtyRect() -> RDPFramebuffer.Rect? {
        var rect = vistara_rect()
        guard vistara_session_take_dirty(session, &rect) else { return nil }
        return .init(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height))
    }

    /// Gives `body` the live framebuffer (32-bit BGRA rows of `stride` bytes).
    /// Returns nil when not connected. The buffer is valid only inside `body`.
    func withFramebuffer<Result>(_ body: (UnsafeBufferPointer<UInt8>, _ stride: Int) -> Result) -> Result? {
        guard let pixels = vistara_session_framebuffer(session) else { return nil }
        let stride = Int(vistara_session_stride(session))
        return body(UnsafeBufferPointer(start: pixels, count: stride * framebufferHeight), stride)
    }

    /// A copy of the framebuffer as 32-bit BGRA rows, or nil when not connected.
    func copyFramebuffer() -> [UInt8]? {
        guard let pixels = vistara_session_framebuffer(session) else { return nil }
        let byteCount = Int(vistara_session_stride(session)) * framebufferHeight
        return Array(UnsafeBufferPointer(start: pixels, count: byteCount))
    }

    func disconnect() {
        vistara_session_disconnect(session)
    }
}

extension RDPCertificate {
    fileprivate init(_ certificate: vistara_certificate) {
        self.init(
            host: String(cString: certificate.host),
            port: certificate.port,
            commonName: String(cString: certificate.common_name),
            subject: String(cString: certificate.subject),
            issuer: String(cString: certificate.issuer),
            fingerprint: String(cString: certificate.fingerprint),
            previousFingerprint: certificate.previous_fingerprint.map { String(cString: $0) }
        )
    }
}
