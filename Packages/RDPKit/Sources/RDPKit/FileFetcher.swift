import Foundation
import os

/// Carries `RDPSession.fetchFiles` to the session thread, which starts each
/// fetch, reports its progress, and ends it. One fetch at a time.
final class FileFetcher: Sendable {
    typealias Continuation = CheckedContinuation<[URL], any Error>

    private struct Request: Sendable {
        var id: UInt64
        var plan: RDPFetchPlan
        var folder: URL
        var progress: @Sendable (RDPFileFetchProgress) -> Void
        var continuation: Continuation

        var urls: [URL] { plan.items.map { folder.appendingPathComponent($0) } }
    }

    private struct State: Sendable {
        var lastID: UInt64 = 0
        var waiting: Request?
        var running: Request?
        var lastProgress: RDPFileFetchProgress?
        /// Fetches cancelled while running, or before they were submitted.
        var cancelled: Set<UInt64> = []
        var hasEnded = false
    }

    private static let log = RDPLogging.logger("Clipboard")
    private let state = OSAllocatedUnfairLock(initialState: State())

    func makeID() -> UInt64 {
        state.withLock { state in
            state.lastID += 1
            return state.lastID
        }
    }

    /// Queues a fetch for the session thread, or ends it at once when another
    /// is running, it was cancelled already, or the session has ended.
    func submit(
        id: UInt64, plan: RDPFetchPlan, folder: URL, progress: @escaping @Sendable (RDPFileFetchProgress) -> Void,
        continuation: Continuation
    ) {
        let rejection: (any Error)? = state.withLock { state in
            if state.cancelled.remove(id) != nil { return CancellationError() }
            if state.hasEnded { return RDPFileFetchError.sessionEnded }
            if state.waiting != nil || state.running != nil { return RDPFileFetchError.busy }
            state.waiting = Request(id: id, plan: plan, folder: folder, progress: progress, continuation: continuation)
            return nil
        }
        if let rejection { continuation.resume(throwing: rejection) }
    }

    /// Cancels a fetch, whether it is waiting, running, or not submitted yet.
    /// A running one ends on the session thread, which removes its partial file.
    func cancel(_ id: UInt64) {
        let waiting: Request? = state.withLock { state in
            guard let waiting = state.waiting, waiting.id == id else {
                state.cancelled.insert(id)
                return nil
            }
            state.waiting = nil
            return waiting
        }
        waiting?.continuation.resume(throwing: CancellationError())
    }

    /// Starts a waiting fetch and follows the running one. Session thread only.
    func service(_ handle: SessionHandle) {
        let started: Request? = state.withLock { state in
            guard let waiting = state.waiting else { return nil }
            state.waiting = nil
            state.running = waiting
            state.lastProgress = nil
            return waiting
        }
        if let started { start(started, on: handle) }
        let current: (request: Request, isCancelled: Bool)? = state.withLock { state in
            guard let running = state.running else { return nil }
            return (request: running, isCancelled: state.cancelled.contains(running.id))
        }
        guard let current else { return }
        let running = current.request
        if current.isCancelled { handle.cancelFetch() }
        let status = handle.fetchStatus
        report(status.progress, of: running)
        switch status.state {
        case .running: return
        case .done:
            Self.log.info("Fetched \(status.progress.filesDone, privacy: .public) files")
            finish(running, with: .success(running.urls))
        case .cancelled: finish(running, with: .failure(CancellationError()))
        case .refused: finish(running, with: .failure(RDPFileFetchError.refusedByRemote))
        case .writeFailed: finish(running, with: .failure(RDPFileFetchError.cannotWrite(code: status.osError)))
        case .listChanged, .idle: finish(running, with: .failure(RDPFileFetchError.noLongerOnClipboard))
        case .channelClosed: finish(running, with: .failure(RDPFileFetchError.sessionEnded))
        }
    }

    /// The session has ended: every fetch ends with it. The session thread
    /// calls this once the session is gone, which removed any partial file.
    func end() {
        let requests: [Request] = state.withLock { state in
            state.hasEnded = true
            let requests = [state.waiting, state.running].compactMap { $0 }
            state.waiting = nil
            state.running = nil
            return requests
        }
        for request in requests {
            request.continuation.resume(throwing: RDPFileFetchError.sessionEnded)
        }
    }

    private func start(_ request: Request, on handle: SessionHandle) {
        do {
            // Only folders: they are there already.
            if try !handle.startFetch(request.plan, into: request.folder) {
                finish(request, with: .success(request.urls))
            }
        } catch {
            finish(request, with: .failure(error))
        }
    }

    private func report(_ progress: RDPFileFetchProgress, of request: Request) {
        let isNew = state.withLock { state in
            guard state.lastProgress != progress else { return false }
            state.lastProgress = progress
            return true
        }
        if isNew { request.progress(progress) }
    }

    private func finish(_ request: Request, with result: Result<[URL], any Error>) {
        state.withLock { state in
            if state.running?.id == request.id { state.running = nil }
            state.cancelled.remove(request.id)
        }
        request.continuation.resume(with: result)
    }
}
