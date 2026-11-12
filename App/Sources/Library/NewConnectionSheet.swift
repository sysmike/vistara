import SwiftUI
import VistaraCore

/// Adds a connection with the little it needs: a computer, and optionally a
/// name and a user name. The full editor arrives with issue #22.
struct NewConnectionSheet: View {
    let add: (Connection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var computer = ""
    @State private var username = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                TextField("Name:", text: $name, prompt: Text("Optional"))
                TextField("Computer:", text: $computer, prompt: Text("server.example.com"))
                TextField("User name:", text: $username, prompt: Text("Optional"))
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(connection == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// What would be added, or nil while the computer is not an address.
    var connection: Connection? {
        Self.connection(name: name, computer: computer, username: username)
    }

    static func connection(name: String, computer: String, username: String) -> Connection? {
        guard let address = LauncherInput.hostAndPort(computer) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = Connection(name: trimmedName.isEmpty ? address.host : trimmedName, host: address.host)
        connection.port = Int(address.port)
        let user = LauncherInput.userAndDomain(username)
        connection.username = user.username
        connection.domain = user.domain ?? ""
        return connection
    }

    private func submit() {
        guard let connection else { return }
        add(connection)
        dismiss()
    }
}
