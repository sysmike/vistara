import Foundation
import RDPKit
import Testing
@testable import Vistara

@Suite
struct DisconnectMessageTests {
    private static let name = "Build Server"
    private static let host = "build01.example.com"

    private func message(_ reason: RDPDisconnectReason) -> DisconnectMessage {
        DisconnectMessage(reason: reason, name: Self.name, host: Self.host)
    }

    /// Every reason a session can end with, every kind of failure included.
    private static var everyReason: [RDPDisconnectReason] {
        let fixed: [RDPDisconnectReason] = [
            .userRequested, .credentialsCancelled, .certificateRejected, .authenticationFailed
        ]
        let failures = RDPFailure.Kind.allCases.flatMap { kind -> [RDPDisconnectReason] in
            let failure = RDPFailure(
                kind: kind, code: 0x0002_0006, name: "ERRCONNECT_CONNECT_FAILED",
                description: "Some description.", osError: ECONNREFUSED
            )
            return [.connectionFailed(failure), .connectionLost(failure)]
        }
        return fixed + failures
    }

    @Test
    func everyMessageFollowsTheWritingRules() {
        for reason in Self.everyReason {
            let message = message(reason)
            let words = [message.title, message.explanation ?? "", message.action?.title ?? ""]
            let context: Comment = "\(reason)"
            #expect(!message.title.isEmpty, context)
            // No bare codes, no "Error", no apology, and no straight quotes.
            for text in words {
                #expect(!text.contains("ERR"), context)
                #expect(!text.contains("0x"), context)
                #expect(!text.localizedCaseInsensitiveContains("error"), context)
                #expect(!text.localizedCaseInsensitiveContains("sorry"), context)
                #expect(!text.contains("\""), context)
                #expect(!text.contains("'"), context)
            }
            // A title is a statement without a full stop; an explanation is a sentence.
            #expect(!message.title.hasSuffix("."), context)
            if let explanation = message.explanation { #expect(explanation.hasSuffix("."), context) }
            // Buttons are title-style verbs, never OK.
            let button = message.action?.title ?? "Fine"
            #expect(button != "OK", context)
            #expect(button.split(separator: " ").allSatisfy { $0.first?.isUppercase == true }, context)
        }
    }

    @Test
    func failuresOfferSomethingToDo() {
        for kind in RDPFailure.Kind.allCases {
            let message = message(.connectionFailed(RDPFailure(kind: kind)))
            #expect(message.action != nil, "\(kind)")
            #expect(message.explanation != nil || kind == .wrongCredentials, "\(kind)")
        }
    }

    @Test
    func aNameThatIsNotFoundIsTheAddressTyped() {
        let message = message(.connectionFailed(RDPFailure(kind: .hostNotFound)))
        #expect(message.title == "Can’t find “build01.example.com”")
        #expect(message.action == .connect("Try Again"))
    }

    @Test
    func refusedAndUnansweredSayDifferentThings() {
        let refused = message(.connectionFailed(RDPFailure(kind: .refused)))
        let silent = message(.connectionFailed(RDPFailure(kind: .notResponding)))
        #expect(refused.title == "“Build Server” refused the connection")
        #expect(silent.title == "“Build Server” isn’t responding")
    }

    @Test
    func accountProblemsOfferAnotherAccount() {
        for kind in [RDPFailure.Kind.accountRestricted, .passwordExpired, .wrongCredentials] {
            #expect(message(.connectionFailed(RDPFailure(kind: kind))).action == .useAnotherAccount, "\(kind)")
        }
        #expect(message(.authenticationFailed).action == .useAnotherAccount)
    }

    @Test
    func aLostConnectionPromisesNothingVistaraDoesNotDo() {
        // Reconnecting by itself arrives with issue #28.
        let message = message(.connectionLost(RDPFailure(kind: .networkLost)))
        #expect(message.action == .connect("Reconnect"))
        #expect(message.explanation?.contains("will reconnect") == false)
    }

    @Test
    func detailIsTechnicalAndNamesNoAccount() throws {
        let failure = RDPFailure(
            kind: .refused, code: 0x0002_0006, name: "ERRCONNECT_CONNECT_FAILED",
            description: "A configuration error prevented a connection to be established.", osError: ECONNREFUSED
        )
        let detail = try #require(message(.connectionFailed(failure)).detail)
        #expect(detail.contains("ERRCONNECT_CONNECT_FAILED (0x00020006)"))
        #expect(detail.contains("Connection refused"))
        #expect(!detail.contains("alice"))
        // Nothing technical to show, nothing to disclose.
        #expect(message(.certificateRejected).detail == nil)
        #expect(message(.connectionLost(RDPFailure(kind: .networkLost))).detail == nil)
    }

    @Test
    func aWrongAddressOffersEditConnectionForASavedConnection() {
        for kind in [RDPFailure.Kind.hostNotFound, .refused, .cannotConnect] {
            let failure = RDPDisconnectReason.connectionFailed(RDPFailure(kind: kind))
            let saved = DisconnectMessage(reason: failure, name: Self.name, host: Self.host, canEditConnection: true)
            #expect(saved.secondaryAction == .editConnection, "\(kind)")
            #expect(saved.action == .connect("Try Again"), "\(kind)")
            #expect(message(failure).secondaryAction == nil, "\(kind)")
        }
        let lost = DisconnectMessage(
            reason: .connectionLost(RDPFailure(kind: .networkLost)), name: Self.name, host: Self.host,
            canEditConnection: true
        )
        #expect(lost.secondaryAction == nil)
    }
}
