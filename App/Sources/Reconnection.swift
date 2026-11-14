import AppKit
import Network
import RDPKit

/// A session being brought back after its network went away.
struct Reconnection: Equatable {
    /// How the session was lost, shown if reconnecting ends without success.
    var lost: RDPDisconnectReason
    /// Attempts started so far.
    var attempts = 0
    /// Whether an attempt is running now, rather than waiting for the next.
    var isTrying = false
}

/// When a lost session is tried again, and how often.
struct ReconnectionPolicy {
    /// The wait before each attempt: about a minute in all, after which the
    /// window says the connection was lost.
    var delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]

    /// Whether a session that ended this way comes back by itself. Only when
    /// the network went away: a session the server, an administrator, or the
    /// user ended on purpose stays ended.
    static func reconnects(after reason: RDPDisconnectReason) -> Bool {
        guard case .connectionLost(let failure) = reason else { return false }
        return failure.kind == .networkLost
    }

    /// Whether an attempt that ended this way is worth another. Only when the
    /// computer or its gateway could not be reached: a refused password, the
    /// gateway's too, a certificate question answered no, or anything the
    /// server or the gateway decided ends reconnecting.
    static func retries(after reason: RDPDisconnectReason) -> Bool {
        switch reason {
        case .connectionFailed(let failure):
            [
                .hostNotFound, .unreachable, .notResponding, .refused, .starting, .cannotConnect, .networkLost,
                .gatewayUnreachable
            ].contains(failure.kind)
        case .connectionLost(let failure):
            failure.kind == .networkLost
        default:
            false
        }
    }
}

/// Moments worth trying again at once instead of waiting: the Mac woke from
/// sleep, or its network came back.
@MainActor
final class ReconnectionTriggers {
    private let chance: () -> Void
    private let monitor = NWPathMonitor()
    private var wakeObserver: (any NSObjectProtocol)?
    /// Unknown until the first report, which is the network as it is now.
    private var hadNetwork: Bool?

    init(_ chance: @escaping () -> Void) {
        self.chance = chance
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.chance() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let hasNetwork = path.status == .satisfied
            MainActor.assumeIsolated { self?.networkChanged(hasNetwork: hasNetwork) }
        }
        monitor.start(queue: .main)
    }

    /// Only a change from no network to some network is a chance.
    private func networkChanged(hasNetwork: Bool) {
        defer { hadNetwork = hasNetwork }
        if hadNetwork == false, hasNetwork { chance() }
    }

    func stop() {
        monitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }
}
