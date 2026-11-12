import SwiftUI

/// Temporary way to start a session until the connection library exists.
/// It asks for the computer only; the session window asks for credentials.
struct LauncherView: View {
    var connect: (SessionTarget) -> Void

    @State private var host = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                TextField("Computer:", text: $host, prompt: Text("server.example.com"))
            }
            Button("Connect", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
        }
        .padding(20)
        .frame(width: 380)
    }

    private var target: SessionTarget? {
        guard let address = LauncherInput.hostAndPort(host) else { return nil }
        return SessionTarget(name: address.host, host: address.host, port: address.port)
    }

    private func submit() {
        guard let target else { return }
        connect(target)
    }
}
