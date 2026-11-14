import Foundation

extension RDPSession {
    /// Fetches files the remote computer copied into `folder`, which is
    /// created if needed: each of `items`, from `list`, and everything inside
    /// those that are folders, at the same paths below `folder`. Returns where
    /// each of `items` ended up.
    ///
    /// The session thread does the fetching, in parts, so the caller's thread
    /// stays free; `progress` is called on the session thread as parts arrive.
    /// Cancelling the task stops the fetch and removes the file being written;
    /// files already fetched stay. One fetch runs at a time.
    public func fetchFiles(
        _ items: [RDPClipboardFile], from list: RDPRemoteFiles, into folder: URL,
        progress: @escaping @Sendable (RDPFileFetchProgress) -> Void = { _ in }
    ) async throws -> [URL] {
        let plan = RDPFetchPlan(items, of: list)
        let fetcher = fetcher
        let id = fetcher.makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetcher.submit(id: id, plan: plan, folder: folder, progress: progress, continuation: continuation)
                wakeSessionThread()
            }
        } onCancel: {
            fetcher.cancel(id)
            wakeSessionThread()
        }
    }
}
