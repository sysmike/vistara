import AppKit
import Observation
import VistaraCore

/// Owns the session windows and knows which one the Session menu acts on.
@MainActor
@Observable
final class SessionCoordinator {
    static let shared = SessionCoordinator()

    /// The session in the main window, if that is a session window.
    private(set) var activeModel: SessionModel?
    @ObservationIgnored private var controllers: [SessionWindowController] = []
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored let trustStore: CertificateTrustStore

    /// Passwords go to the Keychain and trusted certificates to Application
    /// Support, unless a test says otherwise.
    init(
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        trustStore: CertificateTrustStore = SessionCoordinator.defaultTrustStore()
    ) {
        self.credentialStore = credentialStore
        self.trustStore = trustStore
    }

    static func defaultTrustStore() -> CertificateTrustStore {
        let directory = (try? ConnectionStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(VistaraCore.applicationSupportFolderName)
        return CertificateTrustStore(directory: directory)
    }

    var liveSessionCount: Int {
        controllers.filter { $0.model.isLive }.count
    }

    /// Opens a window and connects. A computer that already has a window gets
    /// that window brought forward instead of a second one.
    @discardableResult
    func open(_ target: SessionTarget) -> SessionWindowController {
        if let existing = controllers.first(where: { $0.model.target.credentialKey == target.credentialKey }) {
            existing.show()
            return existing
        }

        let model = SessionModel(target: target, credentialStore: credentialStore, trustStore: trustStore)
        let controller = SessionWindowController(model: model)
        controller.onMainChange = { [weak self, weak model] isMain in
            guard let self, let model else { return }
            if isMain {
                activeModel = model
            } else if activeModel === model {
                activeModel = nil
            }
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if activeModel === controller.model { activeModel = nil }
            controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.observeCertificates()
        model.connect()
        controller.show()
        return controller
    }

    /// Closes the session's window, which disconnects. This is what
    /// Session > Disconnect does.
    func disconnect(_ model: SessionModel) {
        controllers.first { $0.model === model }?.window.close()
    }

    /// Disconnects every session and waits until all have ended, or the
    /// timeout has passed.
    func disconnectAll(timeout: Duration) async {
        let models = controllers.map { $0.model }
        models.forEach { $0.disconnect() }
        let deadline = ContinuousClock.now + timeout
        while models.contains(where: { $0.isLive }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
