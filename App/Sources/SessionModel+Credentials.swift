import Foundation
import RDPKit
import VistaraCore

// MARK: The computer's credentials

extension SessionModel {
    /// Answers the credentials question, if one is open. Nil cancels the
    /// connection.
    func answerCredentials(_ answer: CredentialsAnswer?) {
        let continuation = credentialsAnswer
        credentialsAnswer = nil
        pendingCredentials = nil
        guard let continuation else { return }
        enteredCredentials = answer
        continuation.resume(
            returning: answer.map {
                RDPCredentials(username: $0.username, domain: $0.domainOrNil, password: $0.password)
            }
        )
    }

    /// The credentials for a connection attempt: what is saved, or else what
    /// the user enters in the sheet. Returns nil when the user cancels or the
    /// session is disconnected meanwhile.
    func credentials() async -> RDPCredentials? {
        let saved = try? credentialStore.credentials(for: target.credentialKey)
        let mustAsk = wasRefused || asksForAnotherAccount
        asksForAnotherAccount = false
        if !mustAsk, let saved {
            return RDPCredentials(username: saved.username, domain: saved.domain, password: saved.password)
        }
        let request = CredentialsRequest(
            username: saved?.username ?? target.username,
            domain: saved?.domain ?? target.domain ?? "",
            remember: saved != nil,
            message: wasRefused ? "The user name or password is incorrect." : nil
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                answerCredentials(nil)
                credentialsAnswer = continuation
                pendingCredentials = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerCredentials(nil)
            }
        }
    }

    /// The server accepted what the user entered: save it if asked to, and
    /// otherwise make sure nothing older stays saved.
    func keepOrForgetEnteredCredentials() {
        guard let entered = enteredCredentials else { return }
        enteredCredentials = nil
        if entered.remember {
            let credentials = StoredCredentials(
                username: entered.username, domain: entered.domainOrNil, password: entered.password
            )
            try? credentialStore.save(credentials, for: target.credentialKey, label: "Vistara (\(target.name))")
        } else {
            try? credentialStore.remove(for: target.credentialKey)
        }
    }
}
