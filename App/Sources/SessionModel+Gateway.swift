import Foundation
import RDPKit
import VistaraCore

/// What a gateway asks while connecting: its own account, when it has one,
/// and a message it shows (docs/DESIGN.md, RD Gateway).
struct GatewayQuestions {
    /// Set while the gateway's credentials sheet should be shown.
    var pendingCredentials: CredentialsRequest?
    /// Set while the gateway's message should be shown.
    var pendingMessage: RDPGatewayMessage?
    var credentialsAnswer: CheckedContinuation<RDPCredentials?, Never>?
    var messageAnswer: CheckedContinuation<Bool, Never>?
    /// What the gateway's sheet returned for the attempt in progress. Held
    /// only until that attempt has connected or failed.
    var entered: CredentialsAnswer?
    /// Ask for the gateway's account once, instead of using what is saved.
    var asksForAnotherAccount = false
}

extension SessionModel {
    /// The gateway's own account for a connection attempt: what is saved for
    /// the gateway, or else what the user enters in its sheet, which comes
    /// before the computer's. Nil when the user cancels.
    func gatewayCredentials(for gateway: RDPGateway) async -> RDPCredentials? {
        guard let saved = target.gateway else { return nil }
        let stored = storedGatewayCredentials(for: saved)
        let mustAsk = gatewayQuestions.asksForAnotherAccount
        gatewayQuestions.asksForAnotherAccount = false
        if !mustAsk, let stored {
            return RDPCredentials(username: stored.username, domain: stored.domain, password: stored.password)
        }
        let request = CredentialsRequest(
            username: stored?.username ?? saved.username,
            domain: stored?.domain ?? saved.domain,
            remember: stored != nil
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                answerGatewayCredentials(nil)
                gatewayQuestions.credentialsAnswer = continuation
                gatewayQuestions.pendingCredentials = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerGatewayCredentials(nil)
            }
        }
    }

    /// What is saved for the gateway: for the connection's gateway user, or,
    /// without one, the only account saved for the gateway.
    private func storedGatewayCredentials(for gateway: Connection.Gateway) -> StoredCredentials? {
        if !gateway.username.isEmpty {
            let account = StoredCredentials(
                username: gateway.username, domain: gateway.domain.isEmpty ? nil : gateway.domain, password: ""
            ).account
            return try? credentialStore.credentials(for: gateway.credentialKey(account: account))
        }
        let keys = (try? credentialStore.keys()) ?? []
        let forGateway = keys.filter { $0.lowercased().hasPrefix(gateway.credentialKeyPrefix) }
        guard forGateway.count == 1, let key = forGateway.first else { return nil }
        return try? credentialStore.credentials(for: key)
    }

    /// Answers the gateway's credentials question, if one is open. Nil
    /// cancels the connection.
    func answerGatewayCredentials(_ answer: CredentialsAnswer?) {
        let continuation = gatewayQuestions.credentialsAnswer
        gatewayQuestions.credentialsAnswer = nil
        gatewayQuestions.pendingCredentials = nil
        guard let continuation else { return }
        gatewayQuestions.entered = answer
        continuation.resume(
            returning: answer.map {
                RDPCredentials(username: $0.username, domain: $0.domainOrNil, password: $0.password)
            }
        )
    }

    /// The connection went through: save what the user entered for the
    /// gateway if asked to, under the gateway and user name, so that every
    /// connection through it shares the password; otherwise remove it.
    func keepOrForgetEnteredGatewayCredentials() {
        guard let entered = gatewayQuestions.entered, let gateway = target.gateway else { return }
        gatewayQuestions.entered = nil
        let credentials = StoredCredentials(
            username: entered.username, domain: entered.domainOrNil, password: entered.password
        )
        let key = gateway.credentialKey(account: credentials.account)
        if entered.remember {
            try? credentialStore.save(credentials, for: key, label: "Vistara gateway (\(gateway.host))")
        } else {
            try? credentialStore.remove(for: key)
        }
    }

    /// Connects again and asks for the gateway's account, even when one is saved.
    func reconnectWithAnotherGatewayAccount() {
        guard !isLive else { return }
        gatewayQuestions.asksForAnotherAccount = true
        connect()
    }

    /// Shows what the gateway shows and returns whether the user accepted.
    func decide(_ message: RDPGatewayMessage) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                answerGatewayMessage(accepted: false)
                gatewayQuestions.messageAnswer = continuation
                gatewayQuestions.pendingMessage = message
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answerGatewayMessage(accepted: false)
            }
        }
    }

    /// Answers the gateway's message, if one is shown. Declining does not connect.
    func answerGatewayMessage(accepted: Bool) {
        let continuation = gatewayQuestions.messageAnswer
        gatewayQuestions.messageAnswer = nil
        gatewayQuestions.pendingMessage = nil
        continuation?.resume(returning: accepted)
    }

    /// The attempt ended: nothing the gateway asked stays open, and nothing
    /// entered for it is kept.
    func endGatewayQuestions() {
        answerGatewayCredentials(nil)
        answerGatewayMessage(accepted: false)
        gatewayQuestions.entered = nil
    }
}
