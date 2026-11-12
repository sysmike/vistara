import Foundation
import Testing

@testable import RDPKit

/// Sound from the test server, which sends a steady tone as 16-bit stereo PCM
/// at 44.1 kHz, a tenth of a second at a time.
///
/// Whether the tone is heard depends on the Mac: CI machines may have no
/// output at all. The tests check what reaches the output and say whether it
/// played.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(2)))
struct AudioIntegrationTests {
    private func connect(_ audio: RDPAudioMode) throws -> SessionHandle {
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.audio = audio
        #expect(handle.connect(to: target) { _ in true } == .connected)
        return handle
    }

    /// Processes the session until `done` holds or `seconds` have passed.
    private func run(_ handle: SessionHandle, seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline, handle.poll(timeoutMilliseconds: 100) {}
    }

    @Test func theRemoteComputersSoundReachesThisMacsOutput() throws {
        let handle = try connect(.thisMac)
        defer { handle.disconnect() }
        // One second of the tone.
        run(handle, seconds: 15) { handle.audioStatus.framesReceived >= 44_100 }

        let status = handle.audioStatus
        #expect(status.channelLoaded)
        #expect(status.framesReceived >= 44_100)
        #expect(status.sampleRate == 44_100)
        #expect(status.channels == 2)
        print("Sound output: \(status)")
        if status.outputRunning {
            // A running output keeps up: only the start may be cut short.
            #expect(status.framesDropped < status.framesReceived / 2)
        }
    }

    @Test(arguments: [RDPAudioMode.remote, .off])
    func soundThatDoesNotPlayHereIsNeverSentHere(_ audio: RDPAudioMode) throws {
        let handle = try connect(audio)
        defer { handle.disconnect() }
        run(handle, seconds: 3)

        let status = handle.audioStatus
        #expect(!status.channelLoaded)
        #expect(status.framesReceived == 0)
        #expect(status.outputsOpened == 0)
    }

    @Test func theSoundMovesWhenAnotherDefaultOutputIsPicked() throws {
        let handle = try connect(.thisMac)
        defer { handle.disconnect() }
        run(handle, seconds: 15) { handle.audioStatus.framesReceived > 0 }
        let before = handle.audioStatus

        SessionHandle.pretendAudioOutputChanged()
        run(handle, seconds: 5) { handle.audioStatus.outputChanges > before.outputChanges }
        // The sound goes on after the change.
        let changed = handle.audioStatus
        run(handle, seconds: 5) { handle.audioStatus.framesReceived > changed.framesReceived + 4_410 }

        let after = handle.audioStatus
        #expect(after.outputChanges == before.outputChanges + 1)
        #expect(after.framesReceived > changed.framesReceived)
        // A new output was made, unless this Mac can make none at all.
        if before.outputsOpened > 0 {
            #expect(after.outputsOpened > before.outputsOpened)
        }
    }
}
