import SwiftUI
import VistaraCore

/// The editor's first choice: the remote desktop, or one program of the
/// remote computer in windows of its own (docs/DESIGN.md, RemoteApp).
struct ProgramSection: View {
    @Binding var draft: ConnectionDraft
    /// The problem to show under the program, once worth showing.
    let problem: String?

    var body: some View {
        Section {
            Picker("Open", selection: $draft.opens) {
                Text("The Desktop").tag(Connection.Program.Opens.desktop)
                Text("A Program").tag(Connection.Program.Opens.program)
            }
            .pickerStyle(.segmented)
            if draft.opensProgram {
                TextField("Program", text: $draft.programPath, prompt: Text("||WINWORD"))
                if let problem {
                    Label {
                        Text(problem)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Arguments", text: $draft.programArguments, prompt: Text("Optional"))
            }
        } footer: {
            if draft.opensProgram {
                Text("The program as the remote computer publishes it: “||” and its name, or a path. Its windows "
                    + "open beside your Mac’s own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
