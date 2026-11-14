internal import CFreeRDP
import Foundation

extension SessionHandle {
    struct Target {
        var host: String
        var port: UInt16 = 3389
        var username: String
        var domain: String?
        var password: String
        var width: UInt32 = 1024
        var height: UInt32 = 768
        var scalePercent: UInt32 = 100
        var requiresNLA = true
        /// Off unless asked for, so tests that are not about sound load no
        /// sound channel.
        var audio: RDPAudioMode = .off
        var sharesClipboard = false
        var sharedFolders: [RDPSharedFolder] = []
        var keyboard: RDPKeyboard?
        /// Several monitors; with fewer than two, one of width x height.
        var monitors: [RDPMonitor] = []
        var gateway: Gateway?
    }

    /// The gateway to go through. Without `credentials`, it signs in with the
    /// computer's.
    struct Gateway {
        var host: String
        var port: UInt16 = 443
        var credentials: RDPCredentials?
    }
}

/// Shared folders as the C interface takes them, valid while this lives.
final class SharedFolderList {
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var folders: [vistara_shared_folder] = []
    private(set) var pointer: UnsafeMutablePointer<vistara_shared_folder>?

    init(_ shared: [RDPSharedFolder]) {
        for folder in shared {
            guard let name = strdup(folder.name) else { continue }
            guard let path = strdup(folder.path) else {
                free(name)
                continue
            }
            strings += [name, path]
            folders.append(vistara_shared_folder(name: name, path: path, read_only: folder.isReadOnly))
        }
        guard !folders.isEmpty else { return }
        pointer = .allocate(capacity: folders.count)
        pointer?.initialize(from: folders, count: folders.count)
    }

    var count: Int { folders.count }

    deinit {
        pointer?.deallocate()
        strings.forEach { free($0) }
    }
}

extension SessionHandle.Target {
    /// The C options for these settings, pointing at the given strings. Shared
    /// folders and the certificate question are filled in by the caller.
    func options(
        host: UnsafePointer<CChar>, username: UnsafePointer<CChar>, domain: UnsafePointer<CChar>?,
        password: UnsafePointer<CChar>
    ) -> vistara_connect_options {
        vistara_connect_options(
            host: host,
            port: port,
            username: username,
            domain: domain,
            password: password,
            width: width,
            height: height,
            scale_percent: scalePercent,
            require_nla: requiresNLA,
            play_audio_on_remote: audio == .remote,
            play_audio_here: audio == .thisMac,
            share_clipboard: sharesClipboard,
            shared_folders: nil,
            shared_folder_count: 0,
            monitors: nil,
            monitor_count: 0,
            keyboard_layout: keyboard?.layout ?? 0,
            keyboard_type: keyboard?.type ?? 0,
            keyboard_subtype: keyboard?.subtype ?? 0,
            keyboard_function_keys: keyboard?.functionKeys ?? 0,
            decide_certificate: nil,
            decide_certificate_context: nil,
            gateway_host: nil,
            gateway_port: gateway?.port ?? 0,
            gateway_same_credentials: gateway?.credentials == nil,
            gateway_username: nil,
            gateway_domain: nil,
            gateway_password: nil,
            decide_gateway_message: nil,
            decide_gateway_message_context: nil
        )
    }
}
