import AppKit
import Observation

/// Owns the session windows and knows which one the Session menu acts on.
@MainActor
@Observable
final class SessionCoordinator {
    static let shared = SessionCoordinator()

    /// The session in the main window, if that is a session window.
    private(set) var activeModel: SessionModel?
    @ObservationIgnored private var controllers: [SessionWindowController] = []

    var liveSessionCount: Int {
        controllers.filter { $0.model.isLive }.count
    }

    /// Opens a window and connects. A computer that already has a window gets
    /// that window brought forward instead of a second one.
    @discardableResult
    func open(_ target: SessionTarget, password: String) -> SessionWindowController {
        if let existing = controllers.first(where: { $0.model.target == target }) {
            existing.show()
            return existing
        }

        let model = SessionModel(target: target, password: password)
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
        model.connect()
        controller.show()
        return controller
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
