import Foundation
import Security
import Testing

/// What the running app is allowed, read from its own signature. The tests
/// run inside the app, so this is the app's signature.
@Suite
struct EntitlementsTests {
    private func entitlement(_ name: String) -> CFTypeRef? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    @Test
    func theAppIsSandboxed() {
        #expect(entitlement("com.apple.security.app-sandbox") as? Bool == true)
    }

    /// Shared folders: chosen in the open panel and kept with bookmarks.
    @Test
    func chosenFoldersCanBeUsedAndKept() {
        #expect(entitlement("com.apple.security.files.user-selected.read-write") as? Bool == true)
        #expect(entitlement("com.apple.security.files.bookmarks.app-scope") as? Bool == true)
    }

    /// Sound from the remote computer plays through the output only.
    @Test
    func theMicrophoneIsNeverAskedFor() {
        #expect(entitlement("com.apple.security.device.audio-input") == nil)
        #expect(entitlement("com.apple.security.device.microphone") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil)
    }
}
