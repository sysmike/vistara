import SwiftUI

/// Temporary way to start a session until the connection library exists.
/// The password is passed on and then cleared; it is never stored.
struct LauncherView: View {
    var connect: (SessionTarget, String) -> Void

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                TextField("Computer:", text: $host, prompt: Text("server.example.com"))
                TextField("User name:", text: $username)
                SecureField("Password:", text: $password)
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
        let user = LauncherInput.userAndDomain(username)
        guard !user.username.isEmpty else { return nil }
        return SessionTarget(
            name: address.host,
            host: address.host,
            port: address.port,
            username: user.username,
            domain: user.domain
        )
    }

    private func submit() {
        guard let target else { return }
        connect(target, password)
        password = ""
    }
}
