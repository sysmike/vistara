internal import CFreeRDP

/// Namespace for the Swift wrapper over FreeRDP.
///
/// No C pointers or FreeRDP types leave this module.
public enum RDPKit {
    /// Version of the FreeRDP library this process is linked against.
    public static var freeRDPVersion: String {
        String(cString: vistara_freerdp_version())
    }
}

/// Owns one FreeRDP instance and its context for as long as it lives.
final class SessionHandle {
    private let session: OpaquePointer

    init?() {
        guard let session = vistara_session_create() else { return nil }
        self.session = session
    }

    deinit {
        vistara_session_destroy(session)
    }
}
