import CFreeRDP

/// Namespace for the Swift wrapper over FreeRDP.
///
/// No C pointers or FreeRDP types leave this module.
public enum RDPKit {
    /// Version of the C shim's interface that this build links against.
    public static var shimInterfaceVersion: Int {
        Int(vistara_shim_abi_version())
    }
}
