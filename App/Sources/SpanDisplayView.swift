import RDPKitUI
import SwiftUI

/// The content of a session's window on a display other than the primary
/// one, when the session spans displays (docs/DESIGN.md, Multiple displays).
/// It shows its region of the remote desktop; questions and messages appear
/// in the primary window only.
struct SpanDisplayView: View {
    let model: SessionModel
    /// Which of the session's monitors this display shows.
    let monitorIndex: Int
    @AppStorage("TranslateEditingShortcuts") private var translatesEditingShortcuts = true
    @AppStorage(KeyboardSettingsView.rightCommandKey) private var rightCommandIsWindowsKey = false

    var body: some View {
        ZStack {
            Color.black
            switch model.phase {
            case .connected:
                if let framebuffer = model.framebuffer {
                    RemoteDesktopView(
                        framebuffer: framebuffer,
                        name: model.target.name,
                        translatesEditingShortcuts: translatesEditingShortcuts,
                        rightCommandIsWindowsKey: rightCommandIsWindowsKey,
                        resizesDesktop: false,
                        usesHiDPI: model.target.usesHiDPI,
                        connectedScale: model.connectedScale,
                        region: model.region(forMonitor: monitorIndex),
                        input: { model.send($0) }
                    )
                    .id(ObjectIdentifier(framebuffer))
                }
            case .reconnecting:
                // This display's part of the last picture, dimmed.
                if let region = model.region(forMonitor: monitorIndex),
                    let picture = model.lastFrame?.cropping(to: region) {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .opacity(0.4)
                }
            case .connecting, .disconnected:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
