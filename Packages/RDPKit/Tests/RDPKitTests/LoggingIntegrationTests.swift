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
        if TestHost.allowsFailedLogins {
            let wrong = TestHost.delegate(password: "not the password")
            _ = await runToEnd(RDPSession(configuration: TestHost.configuration, delegate: wrong))
        }
        let right = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        _ = await runToEnd(right) { state, session in
            if case .connected = state { session.disconnect() }
        }

        let lines = capture.all
        let password = TestHost.credentials().password
        let forbidden = [TestHost.configuration.host, TestHost.configuration.username, password, "not the password"]
        Self.expectNoneContain(forbidden, in: lines)
        // Something was caught, so the test is not passing by accident.
        #expect(RDPLogging.redactor.redactionCount > redactionsBefore)
        Self.expectNoRuntimeCheckWarning(in: lines)
        Self.printDefaultLevelOutput(lines)
    }

    /// Many lines through the observer and then letting it go, on the
    /// cooperative pool's small stack. Each line used to wrap the stored
    /// closure once more, and releasing it overflowed the stack (#96). In
    /// this suite because the observer is shared and the suite is serialized.
    @Test func anObserverSurvivesManyLines() async {
        let count = await Task.detached {
            let capture = LogCapture()
            RDPLogging.observeFreeRDP { level, line in capture.append(level, line) }
            for index in 0..<20_000 {
                RDPLogging.deliverToObserver(.debug, "observer test line \(index)")
            }
            RDPLogging.stopObservingFreeRDP()
            // A late line from an earlier session may arrive too.
            return capture.all.filter { $0.1.hasPrefix("observer test line ") }.count
        }.value
        #expect(count == 20_000)
    }

    private static func expectNoneContain(_ forbidden: [String], in lines: [(RDPLogging.FreeRDPLevel, String)]) {
        #expect(lines.count > 20)
        for (level, line) in lines {
            for value in forbidden where line.localizedCaseInsensitiveContains(value) {
                Issue.record("\(level): \(line)")
            }
        }
    }

    /// FreeRDP warns on every connection when built with runtime checks;
    /// the bundled build has none (#70).
    private static func expectNoRuntimeCheckWarning(in lines: [(RDPLogging.FreeRDPLevel, String)]) {
        for (level, line) in lines where line.contains("[runtime-check]") {
            Issue.record("\(level): \(line)")
        }
    }

    /// For the pull request: what default-level output looks like.
    private static func printDefaultLevelOutput(_ lines: [(RDPLogging.FreeRDPLevel, String)]) {
        let shown = lines.filter { $0.0.rawValue >= RDPLogging.FreeRDPLevel.warning.rawValue }
        print("--- FreeRDP output at warning and above, \(shown.count) of \(lines.count) lines captured at debug ---")
        for (level, line) in shown { print("[\(level)] \(line)") }
        print("--- end ---")
    }
}
