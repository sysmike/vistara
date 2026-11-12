import Foundation
import Testing

@testable import RDPKit

/// What a connection attempt hands to FreeRDP, read back from FreeRDP. No
/// server is needed: the settings are applied before connecting, and
/// connecting to a closed port fails at once.
@Suite
struct SettingsMappingTests {
    private func settings(
        _ change: (inout SessionHandle.Target) -> Void = { _ in }
    ) throws -> SessionHandle.GivenSettings {
        let handle = try #require(SessionHandle())
        var target = SessionHandle.Target(host: "127.0.0.1", port: 1, username: "nobody", domain: nil, password: "")
        change(&target)
        _ = handle.connect(to: target)
        return handle.settingsGiven
    }

    @Test func byDefaultOnlyNetworkLevelAuthenticationIsOffered() throws {
        let given = try settings()
        #expect(given.nla)
        #expect(!given.tls)
        #expect(!given.rdp)
    }

    @Test func notRequiringNLAAlsoAllowsTLSButNeverLegacySecurity() throws {
        let given = try settings { $0.requiresNLA = false }
        #expect(given.nla)
        #expect(given.tls)
        #expect(!given.rdp)
    }

    @Test func tlsIsAlwaysVersion1Point2OrNewerAt112Bits() throws {
        for requiresNLA in [true, false] {
            let given = try settings { $0.requiresNLA = requiresNLA }
            #expect(given.tlsMinimumVersion == 0x0303)
            #expect(given.tlsSecurityLevel == 2)
        }
    }

    @Test func eachSoundChoiceTellsTheServerWhereSoundGoes() throws {
        // Remote console audio: played there. Audio playback: sent here.
        let expected: [RDPAudioMode: (remote: Bool, here: Bool)] = [
            .thisMac: (false, true), .remote: (true, false), .off: (false, false)
        ]
        for (mode, flags) in expected {
            let given = try settings { $0.audio = mode }
            #expect(given.remoteConsoleAudio == flags.remote, "\(mode)")
            #expect(given.audioPlayback == flags.here, "\(mode)")
        }
    }

    @Test func theDesktopScaleIsPassedOn() throws {
        try #expect(settings { $0.scalePercent = 200 }.desktopScaleFactor == 200)
    }
}
