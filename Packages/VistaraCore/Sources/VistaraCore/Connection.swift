import Foundation

/// One saved RDP connection. Holds no secrets: the password lives in the
/// Keychain, keyed by `id`.
public struct Connection: Identifiable, Codable, Equatable, Sendable, UnknownFieldPreserving {
    public enum ResolutionMode: String, Codable, Sendable, CaseIterable {
        /// The remote desktop resizes to match the window.
        case matchWindow
        /// The remote desktop keeps its size and is scaled to fit the window.
        case scaleToFit
        /// The remote desktop has the size in `fixedWidth` and `fixedHeight`.
        case fixed
    }

    public enum AudioMode: String, Codable, Sendable, CaseIterable {
        case playOnThisMac
        case playOnRemote
        case off
    }

    public enum CertificatePolicy: String, Codable, Sendable, CaseIterable {
        /// Show an unknown certificate's fingerprint and remember the answer.
        case askOnFirstUse
        /// Connect only when the certificate is already trusted.
        case requireTrusted
    }

    public struct SharedFolder: Codable, Equatable, Sendable {
        public var path: String
        /// Security-scoped bookmark that keeps access inside the App Sandbox.
        public var bookmark: Data?
        public var isReadOnly: Bool

        public init(path: String, bookmark: Data? = nil, isReadOnly: Bool = false) {
            self.path = path
            self.bookmark = bookmark
            self.isReadOnly = isReadOnly
        }
    }

    public static let defaultPort = 3389

    public var id: UUID
    public var name: String
    public var host: String
    public var port = Connection.defaultPort
    public var username = ""
    public var domain = ""

    public var folderID: UUID?
    public var tags: [String] = []
    public var isFavorite = false
    public var lastConnectedAt: Date?

    public var resolutionMode = ResolutionMode.matchWindow
    public var fixedWidth = 1920
    public var fixedHeight = 1080
    public var usesHiDPI = true
    /// One desktop across all of the Mac's displays, in full screen.
    public var usesAllDisplays = false

    public var sharesClipboard = true
    /// Files through the clipboard too, both ways. Needs `sharesClipboard`.
    /// Off unless chosen; older files have none, and `.rdp` files have no
    /// setting for it.
    public var copiesFiles = false
    public var audioMode = AudioMode.playOnThisMac
    public var sharedFolders: [SharedFolder] = []

    public var reconnectsAutomatically = true
    public var requiresNLA = true
    public var certificatePolicy = CertificatePolicy.askOnFirstUse
    /// Never, unless the connection says otherwise; older files have none.
    public var gateway = Gateway()

    /// Lines from an imported `.rdp` file that Vistara has no setting for, kept
    /// as written so an export gives them back. Never holds a password.
    public var additionalRDPSettings: [String] = []

    public var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, host, port, username, domain
        case folderID, tags, isFavorite, lastConnectedAt
        case resolutionMode, fixedWidth, fixedHeight, usesHiDPI, usesAllDisplays
        case sharesClipboard, copiesFiles, audioMode, sharedFolders
        case reconnectsAutomatically, requiresNLA, certificatePolicy, gateway
        case additionalRDPSettings
    }

    public static var knownKeys: Set<String> {
        Set(CodingKeys.allCases.map(\.stringValue))
    }

    public init(id: UUID = UUID(), name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }

    /// Only `id`, `name`, and `host` are required. Anything else that is
    /// missing takes its default, so a hand-edited file still loads.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        domain = try values.decodeIfPresent(String.self, forKey: .domain) ?? domain
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? tags
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? isFavorite
        lastConnectedAt = try values.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        resolutionMode = try values.decodeIfPresent(ResolutionMode.self, forKey: .resolutionMode) ?? resolutionMode
        fixedWidth = try values.decodeIfPresent(Int.self, forKey: .fixedWidth) ?? fixedWidth
        fixedHeight = try values.decodeIfPresent(Int.self, forKey: .fixedHeight) ?? fixedHeight
        usesHiDPI = try values.decodeIfPresent(Bool.self, forKey: .usesHiDPI) ?? usesHiDPI
        usesAllDisplays = try values.decodeIfPresent(Bool.self, forKey: .usesAllDisplays) ?? usesAllDisplays
        sharesClipboard = try values.decodeIfPresent(Bool.self, forKey: .sharesClipboard) ?? sharesClipboard
        copiesFiles = try values.decodeIfPresent(Bool.self, forKey: .copiesFiles) ?? copiesFiles
        audioMode = try values.decodeIfPresent(AudioMode.self, forKey: .audioMode) ?? audioMode
        sharedFolders = try values.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? sharedFolders
        reconnectsAutomatically =
            try values.decodeIfPresent(Bool.self, forKey: .reconnectsAutomatically) ?? reconnectsAutomatically
        requiresNLA = try values.decodeIfPresent(Bool.self, forKey: .requiresNLA) ?? requiresNLA
        certificatePolicy =
            try values.decodeIfPresent(CertificatePolicy.self, forKey: .certificatePolicy) ?? certificatePolicy
        gateway = try values.decodeIfPresent(Gateway.self, forKey: .gateway) ?? gateway
        additionalRDPSettings =
            try values.decodeIfPresent([String].self, forKey: .additionalRDPSettings) ?? additionalRDPSettings
    }
}
