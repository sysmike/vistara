import Foundation
import Testing

@testable import RDPKit

/// What FreeRDP writes to the log during real connections.
@Suite(.serialized, .enabled(if: TestHost.isConfigured, "Set VISTARA_TEST_RDP_HOST to run"), .timeLimit(.minutes(2)))
struct LoggingIntegrationTests {
    /// Collects FreeRDP's log lines as they reach the unified log.
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(RDPLogging.FreeRDPLevel, String)] = []

        func append(_ level: RDPLogging.FreeRDPLevel, _ line: String) {
            lock.withLock { lines.append((level, line)) }
        }

        var all: [(RDPLogging.FreeRDPLevel, String)] {
            lock.withLock { lines }
        }
    }

    @Test func aRefusedAFailedAndASuccessfulLoginLogNoHostUserOrPassword() async {
        let capture = LogCapture()
        RDPLogging.setFreeRDPLevel(.debug)
        RDPLogging.observeFreeRDP { level, line in capture.append(level, line) }
        defer {
            RDPLogging.stopObservingFreeRDP()
            RDPLogging.setFreeRDPLevel(.warning)
        }
        let redactionsBefore = RDPLogging.redactor.redactionCount

        // Nothing listens on port 1: FreeRDP logs the address it tried.
        var closed = TestHost.configuration
        closed.port = 1
        _ = await runToEnd(RDPSession(configuration: closed, delegate: TestHost.delegate()))
        let wrong = TestHost.delegate(password: "not the password")
        _ = await runToEnd(RDPSession(configuration: TestHost.configuration, delegate: wrong))
        let right = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        _ = await runToEnd(right) { state, session in
            if case .connected = state { session.disconnect() }
        }

        let lines = capture.all
        let password = TestHost.credentials().password
        let forbidden = [TestHost.configuration.host, TestHost.configuration.username, password, "not the password"]
        #expect(lines.count > 20)
        for (level, line) in lines {
            for value in forbidden {
                #expect(!line.localizedCaseInsensitiveContains(value), "\(level): \(line)")
            }
        }
        // Something was caught, so the test is not passing by accident.
        #expect(RDPLogging.redactor.redactionCount > redactionsBefore)

        // For the pull request: what default-level output looks like.
        let shown = lines.filter { $0.0.rawValue >= RDPLogging.FreeRDPLevel.warning.rawValue }
        print("--- FreeRDP output at warning and above, \(shown.count) of \(lines.count) lines captured at debug ---")
        for (level, line) in shown { print("[\(level)] \(line)") }
        print("--- end ---")
    }
}
