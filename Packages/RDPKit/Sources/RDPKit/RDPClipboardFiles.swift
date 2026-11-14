import Foundation

/// A file or folder copied through the clipboard, on either side.
public struct RDPClipboardFile: Sendable, Hashable {
    /// Its path below what was copied, parts separated by "/":
    /// "Folder/Inner.txt" for a file inside the copied folder "Folder".
    public var path: String
    /// In bytes. Zero for folders, and for files whose size the remote
    /// computer did not give.
    public var size: UInt64
    public var isFolder: Bool

    public init(path: String, size: UInt64, isFolder: Bool) {
        self.path = path
        self.size = size
        self.isFolder = isFolder
    }

    /// Whether it is one of the items that were copied, not something inside
    /// a copied folder.
    public var isTopLevel: Bool { !path.contains("/") }

    /// Whether it is `item` or lies inside it.
    func isInside(_ item: RDPClipboardFile) -> Bool {
        path == item.path || (item.isFolder && path.hasPrefix(item.path + "/"))
    }
}

/// Files and folders on this Mac to offer to the remote computer, listed from
/// the file URLs that were copied. Folders bring everything in them.
///
/// Only regular files and folders are listed: symbolic links, aliases'
/// targets, and anything else are left out, inside folders too, and so is
/// anything that cannot be read or whose path is too long for Windows.
/// Listing reads every folder, so build an offer off the main thread.
public struct RDPLocalFileOffer: Sendable, Hashable {
    /// Where a listed file is on this Mac, and which file it was.
    struct Source: Sendable, Hashable {
        var path: String
        var device: UInt64
        var inode: UInt64
    }

    /// In order, each folder before what is in it.
    public private(set) var files: [RDPClipboardFile] = []
    /// How many items were left out.
    public private(set) var skippedCount = 0
    /// One for each of `files`; nil for folders.
    private(set) var sources: [Source?] = []

    public init(urls: [URL]) {
        for url in urls {
            guard url.isFileURL else {
                skippedCount += 1
                continue
            }
            let path = url.standardizedFileURL.path
            add(path: path, as: [RDPClipboardFileName.toRemote((path as NSString).lastPathComponent)])
        }
    }

    public var isEmpty: Bool { files.isEmpty }

    private mutating func add(path: String, as name: [String]) {
        let fileManager = FileManager.default
        // attributesOfItem does not follow a symbolic link: it reports the link.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
            let type = attributes[.type] as? FileAttributeType,
            RDPClipboardFileName.fitsRemote(name)
        else {
            skippedCount += 1
            return
        }
        let listed = name.joined(separator: "/")
        switch type {
        case .typeRegular:
            files.append(RDPClipboardFile(path: listed, size: Self.number(attributes[.size]), isFolder: false))
            sources.append(
                Source(
                    path: path, device: Self.number(attributes[.systemNumber]),
                    inode: Self.number(attributes[.systemFileNumber])
                )
            )
        case .typeDirectory:
            files.append(RDPClipboardFile(path: listed, size: 0, isFolder: true))
            sources.append(nil)
            guard let children = try? fileManager.contentsOfDirectory(atPath: path) else {
                skippedCount += 1
                return
            }
            for child in children.sorted() {
                add(path: (path as NSString).appendingPathComponent(child),
                    as: name + [RDPClipboardFileName.toRemote(child)])
            }
        default:
            skippedCount += 1
        }
    }

    private static func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

/// File names between the Mac and Windows.
enum RDPClipboardFileName {
    /// Characters Windows does not allow in a name.
    private static let forbiddenOnWindows = Set("\\/:*?\"<>|")
    /// Names Windows keeps for devices, with or without an extension.
    private static let reservedOnWindows: Set<String> = Set(
        ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
    )
    /// The most UTF-16 code units a path may have in a file list, without
    /// its terminating zero.
    static let longestRemotePath = 259
    /// The most UTF-8 bytes a name may have on the Mac.
    static let longestMacName = 255

    /// A Mac name as Windows allows it: forbidden and control characters
    /// become "_", and so does a trailing dot or space; a reserved name gets
    /// a "_" in front.
    static func toRemote(_ name: String) -> String {
        var escaped = String(name.map { character -> Character in
            let isControl = character.unicodeScalars.allSatisfy { $0.value < 0x20 }
            return forbiddenOnWindows.contains(character) || isControl ? "_" : character
        })
        if let last = escaped.last, last == "." || last == " " {
            escaped.removeLast()
            escaped.append("_")
        }
        let stem = escaped.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        if reservedOnWindows.contains(stem.uppercased()) {
            escaped = "_" + escaped
        }
        return escaped.isEmpty ? "_" : escaped
    }

    /// Whether a path of these parts fits in a file list.
    static func fitsRemote(_ parts: [String]) -> Bool {
        parts.joined(separator: "\\").utf16.count <= longestRemotePath
    }

    /// A path from the remote computer as one below the folder it is fetched
    /// into, or nil when it cannot be one: an absolute path, an empty part,
    /// "." or "..", or a part too long for the Mac. A "/" inside a name
    /// becomes ":", which the Finder shows as "/".
    static func fromRemote(_ name: String) -> String? {
        let parts = name.split(separator: "\\", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "/", with: ":")
        }
        let isUsable = parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= longestMacName
        }
        return isUsable ? parts.joined(separator: "/") : nil
    }
}
