import Foundation
import VistaraCore

/// What a new connection starts with, chosen in Settings > General. Saved
/// connections keep what they have; only the editor's new connection uses
/// these.
struct NewConnectionDefaults: Codable, Equatable {
    static let key = "NewConnectionDefaults"

    /// Match Window or Keep Size, Scale to Fit. A fixed size belongs to one
    /// computer, so it is not offered as a default.
    var resolutionMode = Connection.ResolutionMode.matchWindow
    var usesHiDPI = true
    var usesAllDisplays = false
    var sharesClipboard = true
    var audioMode = Connection.AudioMode.playOnThisMac
    var reconnectsAutomatically = true
    var requiresNLA = true
    var certificatePolicy = Connection.CertificatePolicy.askOnFirstUse

    init() {}

    /// Each setting that is missing keeps its default, so defaults saved
    /// before a setting existed still load.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resolutionMode = try values.decodeIfPresent(Connection.ResolutionMode.self, forKey: .resolutionMode)
            ?? resolutionMode
        usesHiDPI = try values.decodeIfPresent(Bool.self, forKey: .usesHiDPI) ?? usesHiDPI
        usesAllDisplays = try values.decodeIfPresent(Bool.self, forKey: .usesAllDisplays) ?? usesAllDisplays
        sharesClipboard = try values.decodeIfPresent(Bool.self, forKey: .sharesClipboard) ?? sharesClipboard
        audioMode = try values.decodeIfPresent(Connection.AudioMode.self, forKey: .audioMode) ?? audioMode
        reconnectsAutomatically =
            try values.decodeIfPresent(Bool.self, forKey: .reconnectsAutomatically) ?? reconnectsAutomatically
        requiresNLA = try values.decodeIfPresent(Bool.self, forKey: .requiresNLA) ?? requiresNLA
        certificatePolicy = try values.decodeIfPresent(Connection.CertificatePolicy.self, forKey: .certificatePolicy)
            ?? certificatePolicy
    }

    /// What is saved, or the built-in defaults when nothing is or it cannot
    /// be read.
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
            let saved = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return saved
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

extension ConnectionDraft {
    /// A new connection with the defaults from Settings.
    init(defaults: NewConnectionDefaults) {
        self.init()
        resolutionMode = defaults.resolutionMode == .fixed ? .matchWindow : defaults.resolutionMode
        usesHiDPI = defaults.usesHiDPI
        usesAllDisplays = defaults.usesAllDisplays
        sharesClipboard = defaults.sharesClipboard
        audioMode = defaults.audioMode
        reconnectsAutomatically = defaults.reconnectsAutomatically
        requiresNLA = defaults.requiresNLA
        certificatePolicy = defaults.certificatePolicy
    }
}
