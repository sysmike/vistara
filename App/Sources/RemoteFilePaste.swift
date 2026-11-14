import AppKit
import os
import RDPKit

/// The remote computer's files on the Mac's pasteboard (docs/DESIGN.md,
/// Copying files), as issue #134 decided.
///
/// Each item that was copied is one pasteboard item whose file URL is
/// provided only when an app pastes it. The pasteboard asks on the main
/// thread, and the pasting app waits for the answer; so the first paste
/// fetches every item, on the session thread, while the main thread keeps
/// handling events. A paste that takes a while shows its progress and can be
/// cancelled.
///
/// Fetched files go to a folder of Vistara's own, where macOS marks them as
/// downloaded. They are removed when the remote computer copies something
/// else, something else is copied on the Mac, or the session ends.
@MainActor
final class RemoteFilePaste: NSObject {
    typealias Fetch = @Sendable (
        _ items: [RDPClipboardFile], _ list: RDPRemoteFiles, _ folder: URL,
        _ progress: @escaping @Sendable (RDPFileFetchProgress) -> Void
    ) async throws -> [URL]

    /// Which copied item a pasteboard item stands for: its path in the list.
    nonisolated static let itemType = NSPasteboard.PasteboardType("io.github.sysmike.vistara.remote-file")
    /// Where every session's fetched files go, each in a folder of its own.
    static let parentFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vistara Clipboard", isDirectory: true)

    /// This session's folder for fetched files.
    let folder = RemoteFilePaste.parentFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    /// How long a paste runs before its progress shows.
    var progressDelay: Duration = .seconds(1)
    /// Shows a paste's progress, or hides it with nil. A floating panel unless
    /// tests set another.
    var showProgress: (FilePasteProgress?) -> Void

    private let computerName: String
    private let fetch: Fetch
    private var list: RDPRemoteFiles?
    /// Where each item is, once fetched.
    private var fetched: [String: URL]?
    private var isFetching = false
    /// Counts lists, so a fetch that ends after its list was replaced is ignored.
    private var generation = 0
    private static let log = RDPLogging.logger("Clipboard")

    init(computerName: String, fetch: @escaping Fetch) {
        self.computerName = computerName
        self.fetch = fetch
        let panel = FilePastePanel()
        showProgress = { panel.show($0) }
    }

    /// Whether the remote computer's files are offered.
    var hasFiles: Bool { list != nil }

    /// Takes the remote computer's new list, or none, and removes the files
    /// fetched from the one before.
    func replace(with list: RDPRemoteFiles?) {
        generation += 1
        self.list = list.flatMap { $0.topLevel.isEmpty ? nil : $0 }
        fetched = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// One pasteboard item for each item that was copied, provided on paste.
    func pasteboardItems() -> [NSPasteboardItem] {
        guard let list else { return [] }
        return list.topLevel.map { file in
            let item = NSPasteboardItem()
            item.setString(file.path, forType: Self.itemType)
            item.setDataProvider(self, forTypes: [.fileURL])
            return item
        }
    }

    /// The fetched item at `path`, the path a pasteboard item stands for,
    /// fetching every item first if needed. Nil while another paste is
    /// fetching, or when the fetch failed or was cancelled.
    func url(forItemAt path: String?) -> URL? {
        guard let path, let list else { return nil }
        if fetched == nil, !isFetching {
            fetchEverything(of: list)
        }
        return fetched?[path]
    }

    /// Fetches every item of the list, keeping the main thread handling
    /// events until it is done. Another paste asking meanwhile gets nothing.
    private func fetchEverything(of list: RDPRemoteFiles) {
        isFetching = true
        defer { isFetching = false }
        let generation = generation
        let items = list.topLevel
        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outcome = FetchOutcome()
        let fetch = fetch
        let task = Task.detached {
            do {
                outcome.finish(.success(try await fetch(items, list, destination) { outcome.update($0) }))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        let progress = FilePasteProgress(
            computerName: computerName, itemNames: items.map(\.path), cancel: { task.cancel() }
        )
        let started = ContinuousClock.now
        var isShown = false
        while !outcome.isDone {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
            progress.progress = outcome.progress
            if !isShown, ContinuousClock.now - started >= progressDelay {
                isShown = true
                showProgress(progress)
            }
        }
        if isShown { showProgress(nil) }
        switch outcome.result {
        case .success(let urls)? where generation == self.generation:
            fetched = Dictionary(zip(items.map(\.path), urls)) { first, _ in first }
        case .failure(let error)? where !(error is CancellationError):
            let reason = String(describing: error)
            Self.log.error("Fetching \(items.count, privacy: .public) items failed: \(reason, privacy: .public)")
        default:
            break
        }
    }
}

extension RemoteFilePaste: NSPasteboardItemDataProvider {
    /// The pasteboard asks on the main thread (issue #134), whichever thread
    /// the pasting app reads on.
    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL else { return }
        let path = item.string(forType: Self.itemType)
        let url = MainActor.assumeIsolated { self.url(forItemAt: path) }
        if let url { item.setString(url.absoluteString, forType: .fileURL) }
    }
}

/// How a fetch running off the main thread is doing.
private final class FetchOutcome: Sendable {
    private struct State {
        var progress = RDPFileFetchProgress(bytesReceived: 0, bytesExpected: 0, filesDone: 0, fileCount: 0)
        var result: Result<[URL], any Error>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func update(_ progress: RDPFileFetchProgress) { state.withLockUnchecked { $0.progress = progress } }
    func finish(_ result: Result<[URL], any Error>) { state.withLockUnchecked { $0.result = result } }
    var progress: RDPFileFetchProgress { state.withLockUnchecked { $0.progress } }
    var result: Result<[URL], any Error>? { state.withLockUnchecked { $0.result } }
    var isDone: Bool { result != nil }
}
