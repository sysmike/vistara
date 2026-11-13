import Foundation
import RDPKit
import RDPKitUI
import VistaraCore

/// The computer a session window connects to.
struct SessionTarget: Equatable, Sendable {
    /// Shown as the window title.
    var name: String
    var host: String
    var port: UInt16
    /// Suggested in the credentials sheet when nothing is saved.
    var username = ""
    var domain: String?

    /// How the remote desktop gets its size: from the saved connection, or
    /// following the window at full Retina resolution.
    var resolutionMode = Connection.ResolutionMode.matchWindow
    var fixedWidth = 1920
    var fixedHeight = 1080
    var usesHiDPI = true

    /// Security and device options from the saved connection.
    var requiresNLA = true
    var certificatePolicy = Connection.CertificatePolicy.askOnFirstUse
    var audioMode = Connection.AudioMode.playOnThisMac
    var sharesClipboard = true
    var reconnectsAutomatically = true
    /// Opened for each session by SharedFolderAccess.
    var sharedFolders: [Connection.SharedFolder] = []
    /// One desktop across all of the Mac's displays, in full screen
    /// (docs/DESIGN.md, Multiple displays).
    var usesAllDisplays = false

    /// What RDPKit is told about this target, for a desktop of the given size.
    func configuration(desktop: DesktopSize) -> RDPSessionConfiguration {
        let audio: RDPAudioMode = switch audioMode {
        case .playOnThisMac: .thisMac
        case .playOnRemote: .remote
        case .off: .off
        }
        return RDPSessionConfiguration(
            host: host,
            port: port,
            username: username,
            domain: domain,
            desktopWidth: UInt32(desktop.width),
            desktopHeight: UInt32(desktop.height),
            scalePercent: UInt32(desktop.scalePercent),
            requiresNLA: requiresNLA,
            audio: audio,
            sharesClipboard: sharesClipboard,
            reconnectsAutomatically: reconnectsAutomatically
        )
    }

    /// The saved connection this target comes from, if any.
    var connectionID: UUID?

    /// Identifies this target's item in the credential store: the saved
    /// connection's identifier, or else the computer's address.
    var credentialKey: String {
        connectionID?.uuidString ?? "\(host.lowercased()):\(port)"
    }
}

/// What the credentials sheet starts with. Never a password.
struct CredentialsRequest: Equatable {
    var username: String
    var domain: String
    var remember: Bool
    /// Why the sheet is back, after credentials were refused.
    var message: String?
}

/// What the user entered in the credentials sheet.
struct CredentialsAnswer {
    var username: String
    var domain: String
    var password: String
    var remember: Bool

    var domainOrNil: String? {
        domain.isEmpty ? nil : domain
    }
}

/// What the user decided about a certificate.
enum CertificateDecision {
    case cancel
    /// Continue this time and ask again next time.
    case trustOnce
    /// Continue, and remember the certificate for this computer.
    case alwaysTrust
}
