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
