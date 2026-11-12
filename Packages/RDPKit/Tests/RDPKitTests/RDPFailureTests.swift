import Foundation
import Testing

@testable import RDPKit

@Suite
struct RDPFailureTests {
    private static func connect(_ error: UInt32) -> UInt32 { 0x0002_0000 | error }
    private static func server(_ error: UInt32) -> UInt32 { 0x0001_0000 | error }

    /// Every code the table names, with FreeRDP's own name for it. The names
    /// come from the linked library, so a wrong number fails here.
    private static let table: [(code: UInt32, name: String, kind: RDPFailure.Kind)] = [
        (connect(0x04), "ERRCONNECT_DNS_ERROR", .hostNotFound),
        (connect(0x05), "ERRCONNECT_DNS_NAME_NOT_FOUND", .hostNotFound),
        (connect(0x07), "ERRCONNECT_MCS_CONNECT_INITIAL_ERROR", .protocolError),
        (connect(0x09), "ERRCONNECT_AUTHENTICATION_FAILED", .wrongCredentials),
        (connect(0x0A), "ERRCONNECT_INSUFFICIENT_PRIVILEGES", .accountRestricted),
        (connect(0x0C), "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED", .securityMismatch),
        (connect(0x0E), "ERRCONNECT_PASSWORD_EXPIRED", .passwordExpired),
        (connect(0x0F), "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED", .passwordExpired),
        (connect(0x10), "ERRCONNECT_CLIENT_REVOKED", .accountRestricted),
        (connect(0x12), "ERRCONNECT_ACCOUNT_DISABLED", .accountRestricted),
        (connect(0x13), "ERRCONNECT_PASSWORD_MUST_CHANGE", .passwordExpired),
        (connect(0x14), "ERRCONNECT_LOGON_FAILURE", .wrongCredentials),
        (connect(0x15), "ERRCONNECT_WRONG_PASSWORD", .wrongCredentials),
        (connect(0x16), "ERRCONNECT_ACCESS_DENIED", .accountRestricted),
        (connect(0x17), "ERRCONNECT_ACCOUNT_RESTRICTION", .accountRestricted),
        (connect(0x18), "ERRCONNECT_ACCOUNT_LOCKED_OUT", .accountRestricted),
        (connect(0x19), "ERRCONNECT_ACCOUNT_EXPIRED", .accountRestricted),
        (connect(0x1A), "ERRCONNECT_LOGON_TYPE_NOT_GRANTED", .accountRestricted),
        (connect(0x1B), "ERRCONNECT_NO_OR_MISSING_CREDENTIALS", .wrongCredentials),
        (connect(0x1C), "ERRCONNECT_ACTIVATION_TIMEOUT", .notResponding),
        (connect(0x1D), "ERRCONNECT_TARGET_BOOTING", .starting),
        (connect(0x1E), "ERRCONNECT_HYBRID_REQUIRED_BY_SERVER", .securityMismatch),
        (connect(0x1F), "ERRCONNECT_NTLM_BLOCKED", .securityMismatch),
        (server(0x01), "ERRINFO_RPC_INITIATED_DISCONNECT", .endedByServer),
        (server(0x02), "ERRINFO_RPC_INITIATED_LOGOFF", .signedOut),
        (server(0x03), "ERRINFO_IDLE_TIMEOUT", .idleTimeout),
        (server(0x04), "ERRINFO_LOGON_TIMEOUT", .idleTimeout),
        (server(0x05), "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION", .replacedByAnotherConnection),
        (server(0x07), "ERRINFO_SERVER_DENIED_CONNECTION", .accountRestricted),
        (server(0x09), "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES", .accountRestricted),
        (server(0x0A), "ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED", .wrongCredentials),
        (server(0x0B), "ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER", .endedByServer),
        (server(0x0C), "ERRINFO_LOGOFF_BY_USER", .signedOut),
        (server(0x100), "ERRINFO_LICENSE_INTERNAL", .licensing),
        (server(0x10A), "ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS", .licensing),
        (server(0x400), "ERRINFO_CB_DESTINATION_NOT_FOUND", .starting),
        (server(0x10C9), "ERRINFO_UNKNOWN_DATA_PDU_TYPE", .protocolError)
    ]

    @Test func everyCodeInTheTableIsTheErrorFreeRDPNamesIt() {
        for entry in Self.table {
            #expect(RDPFailure.freeRDPName(code: entry.code) == entry.name, "0x\(String(entry.code, radix: 16))")
        }
    }

    @Test func everyCodeInTheTableMeansTheSameBeforeAndAfterConnecting() {
        for entry in Self.table {
            for whileConnected in [false, true] {
                let kind = RDPFailure.kind(code: entry.code, osError: nil, whileConnected: whileConnected)
                #expect(kind == entry.kind, "\(entry.name)")
            }
        }
    }

    @Test func aFailedTCPConnectionIsToldApartByTheSystemError() {
        let failed = Self.connect(0x06)
        #expect(RDPFailure.freeRDPName(code: failed) == "ERRCONNECT_CONNECT_FAILED")
        #expect(RDPFailure.kind(code: failed, osError: ECONNREFUSED, whileConnected: false) == .refused)
        #expect(RDPFailure.kind(code: failed, osError: ETIMEDOUT, whileConnected: false) == .notResponding)
        #expect(RDPFailure.kind(code: failed, osError: EHOSTUNREACH, whileConnected: false) == .unreachable)
        #expect(RDPFailure.kind(code: failed, osError: ENETUNREACH, whileConnected: false) == .unreachable)
        #expect(RDPFailure.kind(code: failed, osError: nil, whileConnected: false) == .cannotConnect)
        #expect(RDPFailure.kind(code: failed, osError: EPERM, whileConnected: false) == .cannotConnect)
    }

    @Test func aBrokenTransportMeansTheNetworkOnceConnected() {
        let transport = Self.connect(0x0D)
        #expect(RDPFailure.freeRDPName(code: transport) == "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        #expect(RDPFailure.kind(code: transport, osError: nil, whileConnected: true) == .networkLost)
        #expect(RDPFailure.kind(code: transport, osError: nil, whileConnected: false) == .cannotConnect)
        #expect(RDPFailure.kind(code: 0, osError: nil, whileConnected: true) == .networkLost)
        #expect(RDPFailure.kind(code: 0, osError: nil, whileConnected: false) == .cannotConnect)
        #expect(RDPFailure.kind(code: 0x0003_0001, osError: nil, whileConnected: true) == .networkLost)
    }

    @Test func technicalDetailNamesTheErrorAndTheSystemError() {
        let failure = RDPFailure(
            kind: .refused, code: Self.connect(0x06), name: "ERRCONNECT_CONNECT_FAILED",
            description: "A configuration error prevented a connection to be established.", osError: ECONNREFUSED
        )
        let lines = failure.technicalDetail.split(separator: "\n").map(String.init)
        #expect(lines.first == "ERRCONNECT_CONNECT_FAILED (0x00020006)")
        #expect(lines.count == 3)
        #expect(lines.last == "System error \(ECONNREFUSED): Connection refused")
        #expect(RDPFailure(kind: .networkLost).technicalDetail.isEmpty)
    }
}
