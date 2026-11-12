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
    var sharesClipboard = true
    var audioMode = Connection.AudioMode.playOnThisMac
    var reconnectsAutomatically = true
    var requiresNLA = true
    var certificatePolicy = Connection.CertificatePolicy.askOnFirstUse

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
        sharesClipboard = defaults.sharesClipboard
        audioMode = defaults.audioMode
        reconnectsAutomatically = defaults.reconnectsAutomatically
        requiresNLA = defaults.requiresNLA
        certificatePolicy = defaults.certificatePolicy
    }
}
