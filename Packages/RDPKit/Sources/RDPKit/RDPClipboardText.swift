/// Line endings between the Mac, which uses LF, and Windows, which uses CR LF.
public enum RDPClipboardText {
    /// Text from the Mac, as the remote computer expects it.
    public static func toRemote(_ text: String) -> String {
        // Normalise first, so CR LF that is already there is not doubled.
        fromRemote(text).replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Text from the remote computer, as the Mac expects it.
    public static func fromRemote(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
