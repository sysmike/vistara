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
        case failed(RDPFailure)
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

    /// The C callback: finds the Swift closure behind the context pointer and
    /// asks it. A certificate that cannot be read is rejected.
    private static let askDecider: vistara_certificate_decider = { context, certificate in
        guard let context, let certificate = RDPCertificate(certificate.pointee) else { return false }
        return Unmanaged<CertificateDecider>.fromOpaque(context).takeUnretainedValue().decide(certificate)
    }

    private let session: OpaquePointer

    init?() {
        // FreeRDP's log goes through Vistara's redaction from the start.
        _ = RDPLogging.installed
        guard let session = vistara_session_create() else { return nil }
        self.session = session
    }

    deinit {
        vistara_session_destroy(session)
    }

    var abortToken: AbortToken { AbortToken(session: session) }

    /// Connects and blocks until connected or failed. `decideCertificate` is
    /// called, on this thread, for the server's certificate. Without it
    /// every certificate is rejected.
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
            return .failed(RDPFailure(kind: .cannotConnect, name: "out of memory"))
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
            options.decide_certificate = Self.askDecider
            options.decide_certificate_context = Unmanaged.passUnretained(decider).toOpaque()
        }

        return withExtendedLifetime(decider) {
            switch vistara_session_connect(session, &options) {
            case VISTARA_CONNECT_OK: .connected
            case VISTARA_CONNECT_CERTIFICATE_UNTRUSTED: .certificateRejected
            case VISTARA_CONNECT_AUTHENTICATION_FAILED: .authenticationFailed
            case VISTARA_CONNECT_CANCELLED: .cancelled
            default: Self.result(for: lastFailure(whileConnected: false))
            }
        }
    }

    /// FreeRDP's name for the last error, such as `FREERDP_ERROR_CONNECT_FAILED`.
    /// Refused credentials go back to the credentials question, whichever
    /// of FreeRDP's several codes reported them.
    private static func result(for failure: RDPFailure) -> ConnectResult {
        failure.kind == .wrongCredentials ? .authenticationFailed : .failed(failure)
    }

    /// The last error, classified.
    func lastFailure(whileConnected: Bool) -> RDPFailure {
        let code = vistara_session_last_error_code(session)
        let osError = vistara_session_last_os_error(session)
        return RDPFailure(
            kind: RDPFailure.kind(
                code: code, osError: osError == 0 ? nil : osError, whileConnected: whileConnected
            ),
            code: code,
            name: String(cString: vistara_error_name(code)),
            description: String(cString: vistara_error_description(code)),
            osError: osError == 0 ? nil : osError
        )
    }

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
        case .desktopSize(let width, let height, let scalePercent):
            vistara_session_request_size(session, UInt32(width), UInt32(height), UInt32(scalePercent))
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
    /// Nil when the server's certificate cannot be read; it is then rejected.
    fileprivate init?(_ certificate: vistara_certificate) {
        let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(certificate.pem), count: certificate.pem_length)
        guard let pem = String(bytes: bytes, encoding: .utf8) else { return nil }
        self.init(host: String(cString: certificate.host), port: certificate.port, pemChain: pem)
    }
}

extension RDPFailure {
    /// FreeRDP's name for an error code, from the linked library.
    static func freeRDPName(code: UInt32) -> String {
        String(cString: vistara_error_name(code))
    }

    /// The shim's diagnostic connection, for tests.
    static func probe(host: String, port: UInt16, timeoutMilliseconds: Int32) -> Int32 {
        vistara_probe_connection(host, port, timeoutMilliseconds)
    }
}
