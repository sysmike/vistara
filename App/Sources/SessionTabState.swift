import AppKit

/// What a session's tab shows beside its name, so a tab in the background
/// says how its session is doing (docs/DESIGN.md, Session tabs).
enum SessionTabState: Equatable {
    /// Connected: nothing to say.
    case none
    /// Connecting or reconnecting, with what VoiceOver reads.
    case progress(String)
    /// Ended, with what the window says about it.
    case ended(String)

    @MainActor
    static func of(_ model: SessionModel) -> SessionTabState {
        switch model.phase {
        case .connecting: .progress("Connecting")
        case .connected: .none
        case .reconnecting: .progress("Reconnecting")
        case .disconnected(let reason): .ended(model.disconnectMessage(for: reason).title)
        }
    }

    /// The tab's accessory view. Shapes, not colours, tell the states apart.
    @MainActor
    func makeView() -> NSView? {
        switch self {
        case .none:
            return nil
        case .progress(let label):
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            indicator.setAccessibilityLabel(label)
            indicator.toolTip = label
            indicator.startAnimation(nil)
            return Self.sized(indicator)
        case .ended(let label):
            let image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: label)
            let view = NSImageView(image: image ?? NSImage())
            view.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .body)
            view.contentTintColor = .secondaryLabelColor
            view.setAccessibilityLabel(label)
            view.toolTip = label
            return Self.sized(view)
        }
    }

    /// A tab's accessory is laid out by its constraints.
    private static func sized(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 16),
            view.heightAnchor.constraint(equalToConstant: 16)
        ])
        return view
    }
}
