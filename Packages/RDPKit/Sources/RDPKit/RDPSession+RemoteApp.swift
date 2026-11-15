import Foundation
import os

extension RDPSession {
    /// How long a RemoteApp session waits after its programs' last window
    /// went before saying so: a program often closes one window just before
    /// it opens the next.
    public static let lastWindowGrace = Duration.seconds(3)

    /// The program's windows as they change: each batch holds the windows
    /// that changed since the last, as they are now, and those deleted, once.
    /// Empty unless the configuration opens a program. Intended for a single
    /// consumer; ends with the session.
    public var remoteWindows: AsyncStream<[RDPRemoteWindow]> { remoteApp.windows }

    /// Whether the program started, moves and resizes the remote computer
    /// asks for, and when the last window has gone. Ends with the session.
    public var remoteAppEvents: AsyncStream<RDPRemoteAppEvent> { remoteApp.events }

    /// What was printed, and the program's windows. Runs on the session thread.
    func publishDocumentsAndWindows(from handle: SessionHandle) {
        printed.publish(handle.takePrinted())
        remoteApp.publish(windows: handle.takeRemoteWindows(), events: handle.takeRemoteAppEvents())
    }
}

/// Passes on what a RemoteApp session's thread takes from the shim.
final class RemoteAppPublisher: Sendable {
    let windows: AsyncStream<[RDPRemoteWindow]>
    let events: AsyncStream<RDPRemoteAppEvent>
    private let windowsContinuation: AsyncStream<[RDPRemoteWindow]>.Continuation
    private let eventsContinuation: AsyncStream<RDPRemoteAppEvent>.Continuation
    private let watch = OSAllocatedUnfairLock(initialState: LastWindowWatch())
    private static let log = RDPLogging.logger("RemoteApp")

    init() {
        (windows, windowsContinuation) = AsyncStream.makeStream(of: [RDPRemoteWindow].self)
        (events, eventsContinuation) = AsyncStream.makeStream(of: RDPRemoteAppEvent.self)
    }

    /// Runs on the session thread after each poll.
    func publish(windows changed: [RDPRemoteWindow], events: [RDPRemoteAppEvent]) {
        for event in events {
            switch event {
            case .programStarted: Self.log.notice("The program started")
            case .programFailed(let failure):
                Self.log.error("The program did not start: \(String(describing: failure), privacy: .public)")
            default: break
            }
            eventsContinuation.yield(event)
        }
        let now = ContinuousClock.now
        let isDue = watch.withLock { watch in
            if !changed.isEmpty { watch.note(changed, at: now) }
            return watch.isDue(at: now, grace: RDPSession.lastWindowGrace)
        }
        if !changed.isEmpty { windowsContinuation.yield(changed) }
        if isDue {
            Self.log.notice("The programs' last window has gone")
            eventsContinuation.yield(.lastWindowClosed)
        }
    }

    func finish() {
        windowsContinuation.finish()
        eventsContinuation.finish()
    }
}

/// Notices when the last window has been gone for a while.
struct LastWindowWatch {
    private var live: Set<UInt32> = []
    private var emptySince: ContinuousClock.Instant?

    mutating func note(_ windows: [RDPRemoteWindow], at now: ContinuousClock.Instant) {
        let hadWindows = !live.isEmpty
        for window in windows {
            if window.isDeleted { live.remove(window.id) } else { live.insert(window.id) }
        }
        if !live.isEmpty {
            emptySince = nil
        } else if hadWindows {
            emptySince = now
        }
    }

    /// True once per time the windows are all gone, after `grace`.
    mutating func isDue(at now: ContinuousClock.Instant, grace: Duration) -> Bool {
        guard let since = emptySince, now - since >= grace else { return false }
        emptySince = nil
        return true
    }
}
