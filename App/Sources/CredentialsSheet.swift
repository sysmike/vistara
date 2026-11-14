import SwiftUI

/// Asks for the account to sign in with: the computer's, or a gateway's own.
/// The password field always starts empty, and what is typed leaves this view
/// only through `answer`.
struct CredentialsSheet: View {
    let name: String
    /// The gateway's name when asking for the gateway's own account.
    var gateway: String?
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

    init(
        name: String, gateway: String? = nil, request: CredentialsRequest,
        answer: @escaping (CredentialsAnswer?) -> Void
    ) {
        self.name = name
        self.gateway = gateway
        self.request = request
        self.answer = answer
        _username = State(initialValue: request.username)
        _domain = State(initialValue: request.domain)
        _remember = State(initialValue: request.remember)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.headline(name: name, gateway: gateway))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
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

    /// What the sheet asks for, naming the gateway and the connection when it
    /// is the gateway's account (docs/DESIGN.md, RD Gateway).
    static func headline(name: String, gateway: String?) -> String {
        guard let gateway else { return "Enter your user name and password for “\(name)”." }
        return "Enter your user name and password for the gateway “\(gateway)”, to connect to “\(name)”."
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
