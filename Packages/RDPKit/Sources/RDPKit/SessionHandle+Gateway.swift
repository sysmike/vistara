internal import CFreeRDP
import Foundation

extension SessionHandle {
    /// Carries the Swift closure for gateway messages through the C
    /// callback's context pointer.
    final class GatewayMessageDecider {
        let decide: (RDPGatewayMessage) -> Bool

        init(_ decide: @escaping (RDPGatewayMessage) -> Bool) {
            self.decide = decide
        }
    }

    /// The C callback, which hands its arguments on to `decideGatewayMessage`.
    static let askGatewayMessageDecider: vistara_gateway_message_decider = {
        SessionHandle.decideGatewayMessage(context: $0, isConsent: $1, mustBeShown: $2, requiresConsent: $3, text: $4, length: $5)
    }

    /// Turns the gateway's UTF-16 text into a message and asks the Swift
    /// closure behind the context pointer.
    private static func decideGatewayMessage(
        context: UnsafeMutableRawPointer?, isConsent: Bool, mustBeShown: Bool, requiresConsent: Bool,
        text: UnsafePointer<UInt16>, length: Int
    ) -> Bool {
        guard let context else { return false }
        let message = RDPGatewayMessage(
            kind: isConsent ? .consent : .notice,
            text: String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF16.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
            mustBeShown: mustBeShown,
            requiresConsent: requiresConsent
        )
        return Unmanaged<GatewayMessageDecider>.fromOpaque(context).takeUnretainedValue().decide(message)
    }

    /// The strings a connection attempt hands to C, copied so that each stays
    /// valid for the whole call. `erase()` overwrites the passwords and frees
    /// them all.
    struct CStrings {
        let host: UnsafeMutablePointer<CChar>?
        let username: UnsafeMutablePointer<CChar>?
        let domain: UnsafeMutablePointer<CChar>?
        let password: UnsafeMutablePointer<CChar>?
        let gatewayHost: UnsafeMutablePointer<CChar>?
        let gatewayUsername: UnsafeMutablePointer<CChar>?
        let gatewayDomain: UnsafeMutablePointer<CChar>?
        let gatewayPassword: UnsafeMutablePointer<CChar>?

        init(_ target: Target) {
            host = strdup(target.host)
            username = strdup(target.username)
            domain = target.domain.flatMap { strdup($0) }
            password = strdup(target.password)
            gatewayHost = target.gateway.flatMap { strdup($0.host) }
            let account = target.gateway?.credentials
            gatewayUsername = account.flatMap { strdup($0.username) }
            gatewayDomain = account?.domain.flatMap { strdup($0) }
            gatewayPassword = account.flatMap { strdup($0.password) }
        }

        func erase() {
            for secret in [password, gatewayPassword] {
                guard let secret else { continue }
                let length = strlen(secret)
                memset_s(secret, length, 0, length)
            }
            let all = [host, username, domain, password, gatewayHost, gatewayUsername, gatewayDomain, gatewayPassword]
            for pointer in all { free(pointer) }
        }
    }
}

extension SessionHandle {
    /// The gateway settings FreeRDP holds, read back after `connect`. For tests.
    struct GivenGatewaySettings: Equatable {
        var enabled: Bool
        /// FreeRDP's TSC_PROXY_MODE_*: 0 never, 1 always.
        var usageMethod: UInt32
        var bypassesLocalAddresses: Bool
        var httpTransport: Bool
        var webSockets: Bool
        var rpcTransport: Bool
        var udpTransport: Bool
        var usesSameCredentials: Bool
        var port: UInt32

        init(_ given: vistara_security_settings) {
            enabled = given.gateway_enabled
            usageMethod = given.gateway_usage_method
            bypassesLocalAddresses = given.gateway_bypass_local
            httpTransport = given.gateway_http_transport
            webSockets = given.gateway_websockets
            rpcTransport = given.gateway_rpc_transport
            udpTransport = given.gateway_udp_transport
            usesSameCredentials = given.gateway_same_credentials
            port = given.gateway_port
        }
    }
}
