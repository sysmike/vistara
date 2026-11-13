internal import CFreeRDP
import Foundation
import os

/// Vistara's one way to log. Everything goes to the unified log under
/// `subsystem`; FreeRDP's own messages are redacted before they get there.
///
/// Use `logger(_:)` with privacy annotations for anything that names a
/// computer or an account. Never log a password, at any level.
public enum RDPLogging {
    public static let subsystem = "io.github.sysmike.vistara"

    /// Hosts, user names, and passwords to keep out of FreeRDP's log lines.
    public static let redactor = LogRedactor()

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    /// FreeRDP's levels, as WinPR numbers them.
    public enum FreeRDPLevel: UInt32, Sendable {
        case trace = 0, debug, info, warning, error, fatal, off
    }

    /// FreeRDP is quiet unless something goes wrong. WLOG_LEVEL in the
    /// environment sets another level, as FreeRDP documents.
    static let defaultFreeRDPLevel = FreeRDPLevel.warning

    private static let freeRDP = logger("FreeRDP")

    /// Receives each FreeRDP line after redaction, besides the unified log.
    /// For tests.
    private static let observer = OSAllocatedUnfairLock<Observer?>(initialState: nil)

    /// The closure in a struct of its own. Kept bare as the lock's generic
    /// state, a closure is wrapped in one more reabstraction thunk each time
    /// the lock hands it out and writes it back, once per line; thousands of
    /// lines later, releasing it overflowed the stack (#96).
    private struct Observer: Sendable {
        let observe: @Sendable (FreeRDPLevel, String) -> Void
    }

    /// Also writes FreeRDP's redacted lines to standard error, for CI logs.
    private static let echoesToStandardError = ProcessInfo.processInfo.environment["VISTARA_LOG_STDERR"] == "1"

    /// Installs the routing once. Called before the first session.
    static let installed: Void = {
        let level = ProcessInfo.processInfo.environment["WLOG_LEVEL"]
            .flatMap(Self.level(named:)) ?? defaultFreeRDPLevel
        vistara_logging_install({ level, function, text in
            RDPLogging.forward(
                level: FreeRDPLevel(rawValue: level) ?? .error,
                function: String(cString: function),
                text: String(cString: text)
            )
        }, level.rawValue)
    }()

    private static func level(named name: String) -> FreeRDPLevel? {
        ["TRACE": .trace, "DEBUG": .debug, "INFO": .info, "WARN": .warning, "ERROR": .error,
         "FATAL": .fatal, "OFF": .off][name.uppercased()]
    }

    /// Sets the level below which FreeRDP's messages are dropped.
    public static func setFreeRDPLevel(_ level: FreeRDPLevel) {
        _ = installed
        vistara_logging_set_level(level.rawValue)
    }

    /// Calls `observe` with every FreeRDP line, redacted, until
    /// `stopObservingFreeRDP()`. For tests.
    public static func observeFreeRDP(_ observe: @escaping @Sendable (FreeRDPLevel, String) -> Void) {
        _ = installed
        observer.withLock { $0 = Observer(observe: observe) }
    }

    public static func stopObservingFreeRDP() {
        observer.withLock { $0 = nil }
    }

    static func forward(level: FreeRDPLevel, function: String, text: String) {
        let line = redactor.redact(function.isEmpty ? text : "[\(function)] \(text)")
        switch level {
        case .trace, .debug: freeRDP.debug("\(line, privacy: .public)")
        case .info: freeRDP.info("\(line, privacy: .public)")
        case .warning: freeRDP.notice("\(line, privacy: .public)")
        case .error: freeRDP.error("\(line, privacy: .public)")
        case .fatal: freeRDP.fault("\(line, privacy: .public)")
        case .off: return
        }
        if echoesToStandardError {
            FileHandle.standardError.write(Data("[FreeRDP \(level)] \(line)\n".utf8))
        }
        deliverToObserver(level, line)
    }

    static func deliverToObserver(_ level: FreeRDPLevel, _ line: String) {
        observer.withLock { $0 }?.observe(level, line)
    }
}
