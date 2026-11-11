internal import CFreeRDP
import Foundation

/// Owns one FreeRDP instance and its context for as long as it lives.
///
/// Internal groundwork for the public session API (issue #8). Not thread-safe:
/// use one handle from one thread.
final class SessionHandle {
    struct Target {
        var host: String
        var port: UInt16 = 3389
        var username: String
        var domain: String?
        var password: String
        var width: UInt32 = 1024
        var height: UInt32 = 768
    }

    enum ConnectResult: Equatable {
        case connected
        /// The server's certificate is not the trusted one. `fingerprint` is
        /// what the server presented, for showing to the user.
        case certificateUntrusted(fingerprint: String?)
        case authenticationFailed
        case failed(errorName: String)
    }

    private let session: OpaquePointer

    init?() {
        guard let session = vistara_session_create() else { return nil }
        self.session = session
    }

    deinit {
        vistara_session_destroy(session)
    }

    /// Connects with Network Level Authentication and blocks until connected
    /// or failed. A certificate OpenSSL cannot verify is accepted only when
    /// its fingerprint equals `trustedFingerprint`.
    func connect(to target: Target, trustedFingerprint: String? = nil) -> ConnectResult {
        // strdup copies so every pointer stays valid for the whole call.
        let hostCopy = strdup(target.host)
        let usernameCopy = strdup(target.username)
        let domain = target.domain.flatMap { strdup($0) }
        let passwordCopy = strdup(target.password)
        let fingerprint = trustedFingerprint.flatMap { strdup($0) }
        defer {
            if let passwordCopy {
                let length = strlen(passwordCopy)
                memset_s(passwordCopy, length, 0, length)
            }
            for pointer in [hostCopy, usernameCopy, domain, passwordCopy, fingerprint] { free(pointer) }
        }
        guard let host = hostCopy, let username = usernameCopy, let password = passwordCopy else {
            return .failed(errorName: "out of memory")
        }

        var options = vistara_connect_options(
            host: host,
            port: target.port,
            username: username,
            domain: domain,
            password: password,
            width: target.width,
            height: target.height,
            trusted_fingerprint: fingerprint
        )

        switch vistara_session_connect(session, &options) {
        case VISTARA_CONNECT_OK:
            return .connected
        case VISTARA_CONNECT_CERTIFICATE_UNTRUSTED:
            return .certificateUntrusted(fingerprint: presentedFingerprint)
        case VISTARA_CONNECT_AUTHENTICATION_FAILED:
            return .authenticationFailed
        default:
            return .failed(errorName: String(cString: vistara_session_last_error_name(session)))
        }
    }

    /// Fingerprint of the certificate the server presented, if it needed a decision.
    var presentedFingerprint: String? {
        vistara_session_presented_fingerprint(session).map { String(cString: $0) }
    }

    /// Waits for network activity and processes it. False once disconnected.
    func poll(timeoutMilliseconds: UInt32) -> Bool {
        vistara_session_poll(session, timeoutMilliseconds)
    }

    var framebufferWidth: Int { Int(vistara_session_width(session)) }
    var framebufferHeight: Int { Int(vistara_session_height(session)) }

    /// Number of paint cycles that changed the framebuffer since connecting.
    var paintCount: UInt64 { vistara_session_paint_count(session) }

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
