internal import CFreeRDP
import Foundation

/// Where a fetch of files stands.
enum FetchState: Equatable {
    case idle, running, done, cancelled, refused, writeFailed, listChanged, channelClosed
}

/// Files through the clipboard. Logs count files and never name them.
extension SessionHandle {
    private static let filesLog = RDPLogging.logger("Clipboard")

    /// How the running or last fetch is doing.
    struct FetchStatus: Equatable {
        var state: FetchState
        var progress: RDPFileFetchProgress
        var osError: Int32
    }

    /// Offers the files to the remote computer in place of any text. False
    /// when the connection does not copy files.
    func offerClipboardFiles(_ offer: RDPLocalFileOffer) -> Bool {
        let offered = Self.withLocalFiles(offer) { entries in
            vistara_session_offer_local_files(session, entries.baseAddress, entries.count)
        }
        if offered {
            let count = offer.files.count
            let skipped = offer.skippedCount
            Self.filesLog.info("Offering \(count, privacy: .public) items, \(skipped, privacy: .public) left out")
        }
        return offered
    }

    /// The remote computer's files, if they changed since the last call:
    /// empty once it copies something else.
    func takeRemoteFiles() -> RDPRemoteFiles? {
        var entries: UnsafeMutablePointer<vistara_remote_file>?
        var count = 0
        var listID: UInt64 = 0
        guard vistara_session_take_remote_files(session, &entries, &count, &listID) else { return nil }
        defer { vistara_remote_files_free(entries, count) }
        return Self.remoteFiles(UnsafeBufferPointer(start: entries, count: count), listID: listID)
    }

    /// Creates the plan's folders below `folder` and starts fetching its
    /// files there. False when there is nothing to fetch.
    func startFetch(_ plan: RDPFetchPlan, into folder: URL) throws -> Bool {
        let fileManager = FileManager.default
        let parents = plan.files.map { ($0.path as NSString).deletingLastPathComponent }.filter { !$0.isEmpty }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for path in plan.folders + parents {
                try fileManager.createDirectory(
                    at: folder.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true
                )
            }
        } catch {
            throw RDPFileFetchError.cannotWrite(code: Self.posixCode(of: error))
        }
        guard !plan.files.isEmpty else { return false }
        let destinations = plan.files.map { strdup(folder.appendingPathComponent($0.path).path) }
        defer { destinations.forEach { free($0) } }
        var items: [vistara_fetch_item] = []
        for (file, destination) in zip(plan.files, destinations) {
            guard let destination else { throw RDPFileFetchError.cannotWrite(code: ENOMEM) }
            items.append(vistara_fetch_item(list_index: file.listIndex, destination: destination))
        }
        let started = items.withUnsafeBufferPointer { items in
            guard let first = items.baseAddress else { return false }
            return vistara_session_start_fetch(session, plan.listID, first, items.count)
        }
        guard started else { throw RDPFileFetchError.noLongerOnClipboard }
        Self.filesLog.info("Fetching \(plan.files.count, privacy: .public) files")
        return true
    }

    /// Ends a running fetch and removes the file it was writing.
    func cancelFetch() {
        vistara_session_cancel_fetch(session)
    }

    var fetchStatus: FetchStatus {
        var status = vistara_fetch_status()
        vistara_session_read_fetch(session, &status)
        let state: FetchState =
            switch status.state {
            case VISTARA_FETCH_RUNNING: .running
            case VISTARA_FETCH_DONE: .done
            case VISTARA_FETCH_CANCELLED: .cancelled
            case VISTARA_FETCH_REFUSED: .refused
            case VISTARA_FETCH_WRITE_FAILED: .writeFailed
            case VISTARA_FETCH_LIST_CHANGED: .listChanged
            case VISTARA_FETCH_CHANNEL_CLOSED: .channelClosed
            default: .idle
            }
        let progress = RDPFileFetchProgress(
            bytesReceived: status.bytes_received, bytesExpected: status.bytes_expected,
            filesDone: Int(status.files_done), fileCount: Int(status.file_count)
        )
        return FetchStatus(state: state, progress: progress, osError: status.os_error)
    }

    // MARK: File lists

    /// The packed file list the remote computer would receive. For tests.
    static func encodeFileList(_ offer: RDPLocalFileOffer) -> Data? {
        withLocalFiles(offer) { entries in
            var length = 0
            guard let first = entries.baseAddress, let data = vistara_file_list_encode(first, entries.count, &length)
            else { return nil }
            defer { free(data) }
            return Data(bytes: data, count: length)
        }
    }

    /// A packed file list read as one from the remote computer. For tests.
    static func decodeFileList(_ data: Data) -> RDPRemoteFiles? {
        data.withUnsafeBytes { bytes in
            guard let first = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var entries: UnsafeMutablePointer<vistara_remote_file>?
            var count = 0
            guard vistara_file_list_decode(first, bytes.count, &entries, &count) else { return nil }
            defer { vistara_remote_files_free(entries, count) }
            return remoteFiles(UnsafeBufferPointer(start: entries, count: count), listID: 0)
        }
    }

    private static func remoteFiles(_ entries: UnsafeBufferPointer<vistara_remote_file>, listID: UInt64)
        -> RDPRemoteFiles
    {
        var files: [RDPClipboardFile] = []
        var indices: [UInt32] = []
        for (index, entry) in entries.enumerated() {
            guard let path = RDPClipboardFileName.fromRemote(String(cString: entry.name)) else { continue }
            files.append(RDPClipboardFile(path: path, size: entry.size, isFolder: entry.is_folder))
            indices.append(UInt32(index))
        }
        return RDPRemoteFiles(
            files: files, skippedCount: entries.count - files.count, listID: listID, listIndices: indices
        )
    }

    /// The offer as the C interface takes it, valid inside `body`. Names use
    /// "\" between their parts, as Windows does.
    private static func withLocalFiles<Result>(
        _ offer: RDPLocalFileOffer, _ body: (UnsafeBufferPointer<vistara_local_file>) -> Result
    ) -> Result {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        var entries: [vistara_local_file] = []
        for (file, source) in zip(offer.files, offer.sources) {
            guard let name = strdup(file.path.replacingOccurrences(of: "/", with: "\\")) else { continue }
            strings.append(name)
            guard let path = strdup(source?.path ?? "") else { continue }
            strings.append(path)
            entries.append(
                vistara_local_file(
                    name: name, path: path, size: file.size, is_folder: file.isFolder,
                    device: source?.device ?? 0, inode: source?.inode ?? 0
                )
            )
        }
        return entries.withUnsafeBufferPointer(body)
    }

    private static func posixCode(of error: Error) -> Int32 {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
}
