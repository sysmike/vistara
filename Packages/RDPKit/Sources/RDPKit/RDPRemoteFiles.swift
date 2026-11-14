import Foundation

/// The files and folders the remote computer copied, as names and sizes.
/// Their contents are fetched only on request, with
/// `RDPSession.fetchFiles(_:from:into:progress:)`.
public struct RDPRemoteFiles: Sendable, Equatable {
    /// In the remote computer's order, which lists a folder before what is in it.
    public let files: [RDPClipboardFile]
    /// Entries left out because their names cannot be used on the Mac.
    public let skippedCount: Int
    /// Which list of the session this is.
    let listID: UInt64
    /// Each file's index in the remote computer's list.
    let listIndices: [UInt32]

    init(files: [RDPClipboardFile], skippedCount: Int, listID: UInt64, listIndices: [UInt32]) {
        self.files = files
        self.skippedCount = skippedCount
        self.listID = listID
        self.listIndices = listIndices
    }

    /// No files: the remote computer copied something else.
    public var isEmpty: Bool { files.isEmpty }

    /// The items that were copied, without what is inside copied folders.
    public var topLevel: [RDPClipboardFile] { files.filter(\.isTopLevel) }
}

/// How a fetch is going.
public struct RDPFileFetchProgress: Sendable, Equatable {
    public var bytesReceived: UInt64
    /// The size of all files being fetched, as far as known.
    public var bytesExpected: UInt64
    public var filesDone: Int
    public var fileCount: Int

    public init(bytesReceived: UInt64, bytesExpected: UInt64, filesDone: Int, fileCount: Int) {
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.filesDone = filesDone
        self.fileCount = fileCount
    }

    /// From 0 to 1.
    public var fractionCompleted: Double {
        bytesExpected == 0 ? (fileCount == 0 ? 1 : Double(filesDone) / Double(fileCount))
            : Double(bytesReceived) / Double(bytesExpected)
    }
}

/// Why fetching files failed. Cancelling the task throws `CancellationError`.
public enum RDPFileFetchError: Error, Sendable, Equatable {
    /// The remote computer copied something else, or the connection does not
    /// copy files: these files can no longer be fetched.
    case noLongerOnClipboard
    /// The remote computer refused a file or sent less of it than it listed.
    case refusedByRemote
    /// A file or folder could not be created here. `code` is the POSIX error.
    case cannotWrite(code: Int32)
    /// Another fetch of this session is still running.
    case busy
    /// The session ended first.
    case sessionEnded
}

/// What one fetch writes: folders to create and files to fetch, below its folder.
struct RDPFetchPlan: Sendable, Equatable {
    struct File: Sendable, Equatable {
        var listIndex: UInt32
        var path: String
    }

    var listID: UInt64
    var folders: [String] = []
    var files: [File] = []
    /// Where each item asked for ends up, below the folder.
    var items: [String] = []

    /// `items` and everything inside those that are folders. Items not in
    /// `list` are left out.
    init(_ items: [RDPClipboardFile], of list: RDPRemoteFiles) {
        listID = list.listID
        var included = Set<Int>()
        for item in items where list.files.contains(item) {
            self.items.append(item.path)
            for (index, file) in list.files.enumerated() where file.isInside(item) {
                guard included.insert(index).inserted else { continue }
                if file.isFolder {
                    folders.append(file.path)
                } else {
                    files.append(File(listIndex: list.listIndices[index], path: file.path))
                }
            }
        }
    }
}
