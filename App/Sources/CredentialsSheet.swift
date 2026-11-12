import SwiftUI

/// Asks for the account to sign in with. The password field always starts
/// empty, and what is typed leaves this view only through `answer`.
struct CredentialsSheet: View {
    let name: String
    let request: CredentialsRequest
    /// Nil when the user cancels.
    let answer: (CredentialsAnswer?) -> Void

    private enum Field {
        case username, password
    }

    @State private var username: String
    @State private var domain: String
    @State private var password = ""
    @State private var remember: Bool
    @FocusState private var focus: Field?

    init(name: String, request: CredentialsRequest, answer: @escaping (CredentialsAnswer?) -> Void) {
        self.name = name
        self.request = request
        self.answer = answer
        _username = State(initialValue: request.username)
        _domain = State(initialValue: request.domain)
        _remember = State(initialValue: request.remember)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your user name and password for “\(name)”.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let message = request.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("User name:", text: $username)
                    .focused($focus, equals: .username)
                TextField("Domain:", text: $domain, prompt: Text("Optional"))
                SecureField("Password:", text: $password)
                    .focused($focus, equals: .password)
                Toggle("Remember this password in my keychain", isOn: $remember)
            }

            HStack {
                Spacer()
                Button("Cancel") { answer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focus = username.isEmpty ? .username : .password }
    }

    /// "DOMAIN\user" typed into the user name field counts as both.
    private var account: (username: String, domain: String) {
        let typedDomain = domain.trimmingCharacters(in: .whitespaces)
        let typed = LauncherInput.userAndDomain(username)
        return (typed.username, typedDomain.isEmpty ? typed.domain ?? "" : typedDomain)
    }

    private func submit() {
        let typed = account
        guard !typed.username.isEmpty else { return }
        let entered = CredentialsAnswer(
            username: typed.username, domain: typed.domain, password: password, remember: remember
        )
        password = ""
        answer(entered)
    }
}
