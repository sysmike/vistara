import Foundation
import VistaraCore

/// A connection being edited, as the editor's fields hold it, with what is
/// wrong with it in words that say how to fix it.
struct ConnectionDraft: Equatable {
    var name = ""
    var host = ""
    var port = String(Connection.defaultPort)
    var username = ""
    var domain = ""
    var folderID: UUID?
    var tags: [String] = []

    var resolutionMode = Connection.ResolutionMode.matchWindow
    var fixedWidth = "1920"
    var fixedHeight = "1080"
    var usesHiDPI = true
    var usesAllDisplays = false

    var sharesClipboard = true
    var audioMode = Connection.AudioMode.playOnThisMac
    /// The only folders the remote computer sees.
    var sharedFolders: [Connection.SharedFolder] = []

    var reconnectsAutomatically = true
    var requiresNLA = true
    var certificatePolicy = Connection.CertificatePolicy.askOnFirstUse

    /// The connection being edited, which keeps everything the editor does
    /// not show. A new connection when nil.
    private var original: Connection?

    init() {}

    init(_ connection: Connection) {
        original = connection
        name = connection.name
        host = connection.host
        port = String(connection.port)
        username = connection.username
        domain = connection.domain
        folderID = connection.folderID
        tags = connection.tags
        resolutionMode = connection.resolutionMode
        fixedWidth = String(connection.fixedWidth)
        fixedHeight = String(connection.fixedHeight)
        usesHiDPI = connection.usesHiDPI
        usesAllDisplays = connection.usesAllDisplays
        sharesClipboard = connection.sharesClipboard
        audioMode = connection.audioMode
        sharedFolders = connection.sharedFolders
        reconnectsAutomatically = connection.reconnectsAutomatically
        requiresNLA = connection.requiresNLA
        certificatePolicy = connection.certificatePolicy
    }

    var isNew: Bool { original == nil }

    // MARK: Shared folders

    /// Adds folders, skipping any already shared.
    mutating func share(_ folders: [Connection.SharedFolder]) {
        for folder in folders where !sharedFolders.contains(where: { $0.path == folder.path }) {
            sharedFolders.append(folder)
        }
    }

    mutating func stopSharing(_ path: String) {
        sharedFolders.removeAll { $0.path == path }
    }

    // MARK: Validation

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the host can't be used, or nil.
    var hostProblem: String? {
        let host = trimmedHost
        if host.isEmpty { return "Enter the computer’s name or address." }
        if host.contains("://") || host.contains("/") {
            return "Enter only the computer’s name, without “rdp://” or a path."
        }
        if host.contains(where: \.isWhitespace) { return "A computer’s name can’t contain spaces." }
        // One colon followed by digits: a port typed into the wrong field.
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) {
            return "Enter the port in the Port field."
        }
        return nil
    }

    var portValue: Int? {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    var portProblem: String? {
        portValue == nil ? "Enter a port from 1 to 65535." : nil
    }

    private static let sides = 200...8192

    var sizeProblem: String? {
        guard resolutionMode == .fixed else { return nil }
        let width = Int(fixedWidth.trimmingCharacters(in: .whitespaces))
        let height = Int(fixedHeight.trimmingCharacters(in: .whitespaces))
        guard let width, let height, Self.sides.contains(width), Self.sides.contains(height) else {
            return "Enter a width and height from 200 to 8192."
        }
        return nil
    }

    var isValid: Bool { hostProblem == nil && portProblem == nil && sizeProblem == nil }

    /// One line under a choice that makes the connection less safe.
    var nlaWarning: String? {
        requiresNLA ? nil : "The computer will show its sign-in screen to anyone before checking who they are."
    }

    /// Tags without blanks and without repeats that differ only in case,
    /// in the order typed.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    // MARK: Result

    /// The connection to save, or nil while something is invalid.
    func connection() -> Connection? {
        guard isValid, let port = portValue else { return nil }
        var connection = original ?? Connection(name: "", host: "")
        let host = trimmedHost
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.name = name.isEmpty ? host : name
        connection.host = host
        connection.port = port
        let user = LauncherInput.userAndDomain(username)
        let typedDomain = domain.trimmingCharacters(in: .whitespaces)
        connection.username = user.username
        connection.domain = typedDomain.isEmpty ? user.domain ?? "" : typedDomain
        connection.folderID = folderID
        connection.tags = Self.normalizedTags(tags)
        connection.resolutionMode = resolutionMode
        if resolutionMode == .fixed, let width = Int(fixedWidth), let height = Int(fixedHeight) {
            connection.fixedWidth = width
            connection.fixedHeight = height
        }
        connection.usesHiDPI = usesHiDPI
        connection.usesAllDisplays = usesAllDisplays
        connection.sharesClipboard = sharesClipboard
        connection.audioMode = audioMode
        connection.sharedFolders = sharedFolders
        connection.reconnectsAutomatically = reconnectsAutomatically
        connection.requiresNLA = requiresNLA
        connection.certificatePolicy = certificatePolicy
        return connection
    }
}
