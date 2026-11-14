import Foundation
import Testing

@testable import VistaraCore

/// The gateway in the connection model and in `.rdp` files (#123).
@Suite
struct GatewayModelTests {
    @Test func aConnectionWithoutAGatewayInItsFileUsesNone() throws {
        let json = #"{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "A", "host": "a"}"#
        let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        #expect(connection.gateway == Connection.Gateway())
        #expect(connection.gateway.usage == .never)
        #expect(!connection.gateway.isUsed)
    }

    @Test func theGatewaySurvivesSavingAndLoading() throws {
        var connection = Connection(name: "A", host: "a")
        connection.gateway = .init(
            usage: .always, host: "gw.example.com", port: 8443, signIn: .anotherAccount, username: "kim", domain: "CORP"
        )
        let data = try JSONEncoder().encode(connection)
        #expect(try JSONDecoder().decode(Connection.self, from: data) == connection)
    }

    @Test func theAddressCarriesAPortOnlyWhenItIsNot443() {
        #expect(Connection.Gateway(host: "gw").address == "gw")
        #expect(Connection.Gateway(host: "gw", port: 8443).address == "gw:8443")
        #expect(Connection.Gateway(host: "fd00::1", port: 8443).address == "[fd00::1]:8443")
        let split = Connection.Gateway.split(address: "gw:8443")
        #expect(split.host == "gw" && split.port == 8443)
        #expect(Connection.Gateway.split(address: "gw").port == nil)
    }

    @Test func usedOnlyWhenAlwaysAndAnAddressIsGiven() {
        #expect(Connection.Gateway(usage: .always, host: "gw").isUsed)
        #expect(!Connection.Gateway(usage: .always, host: "").isUsed)
        #expect(!Connection.Gateway(usage: .never, host: "gw").isUsed)
    }
}

@Suite
struct GatewayRDPFileTests {
    private func connection(_ text: String) throws -> Connection {
        try RDPFileMapping.connection(from: RDPFile(text: "full address:s:pc\n" + text), name: "A")
    }

    @Test func theMicrosoftClientsLinesImport() throws {
        let gateway = try connection("""
            gatewayhostname:s:gw.example.com:8443
            gatewayusagemethod:i:1
            gatewaycredentialssource:i:0
            promptcredentialonce:i:1
            """).gateway
        #expect(gateway == .init(usage: .always, host: "gw.example.com", port: 8443, signIn: .sameAsComputer))
    }

    @Test func anotherAccountWithItsUserName() throws {
        let gateway = try connection("""
            gatewayhostname:s:gw
            gatewayusagemethod:i:1
            promptcredentialonce:i:0
            gatewayusername:s:CORP\\kim
            """).gateway
        #expect(gateway.signIn == .anotherAccount)
        #expect(gateway.username == "kim")
        #expect(gateway.domain == "CORP")
        #expect(gateway.port == 443)
    }

    /// "Only when needed" and the administrator's settings become Always, which
    /// the import notice says; 0 and 4 are Never.
    @Test func eachUsageMethodBecomesNeverOrAlways() throws {
        let expected: [Int: Connection.Gateway.Usage] = [0: .never, 1: .always, 2: .always, 3: .always, 4: .never]
        for (method, usage) in expected {
            let text = "gatewayhostname:s:gw\ngatewayusagemethod:i:\(method)"
            #expect(try connection(text).gateway.usage == usage, "method \(method)")
            let file = RDPFile(text: "full address:s:pc\n" + text)
            #expect(RDPFileMapping.usesGatewayOnlySometimes(file) == [2, 3].contains(method), "method \(method)")
        }
    }

    @Test func aGatewayWithoutAnAddressIsNotUsed() throws {
        #expect(try connection("gatewayhostname:s:\ngatewayusagemethod:i:1").gateway.usage == .never)
        #expect(try connection("gatewayhostname:s:gw").gateway.usage == .always)
        #expect(try connection("").gateway == Connection.Gateway())
    }

    @Test func noGatewayWritesNoGatewayLines() {
        let file = RDPFileMapping.file(from: Connection(name: "A", host: "pc"))
        #expect(file.settings.allSatisfy { !RDPFileMapping.gatewayKeys.contains($0.key) })
    }

    @Test func aGatewaySurvivesExportAndImport() throws {
        var original = Connection(name: "A", host: "pc")
        for gateway in [
            Connection.Gateway(usage: .always, host: "gw", port: 8443, signIn: .anotherAccount, username: "kim",
                               domain: "CORP"),
            Connection.Gateway(usage: .always, host: "gw"),
            // Never keeps its address.
            Connection.Gateway(usage: .never, host: "gw", port: 8443)
        ] {
            original.gateway = gateway
            let file = RDPFileMapping.file(from: original)
            let back = try RDPFileMapping.connection(from: RDPFile(text: file.text), name: "A")
            #expect(back.gateway == gateway)
            #expect(back.additionalRDPSettings.isEmpty)
        }
    }

    @Test func theFileSaysHowToSignIn() {
        var connection = Connection(name: "A", host: "pc")
        connection.gateway = .init(usage: .always, host: "gw", signIn: .anotherAccount, username: "kim")
        let file = RDPFileMapping.file(from: connection)
        #expect(file.string("gatewayhostname") == "gw")
        #expect(file.integer("gatewayusagemethod") == 1)
        #expect(file.integer("gatewaycredentialssource") == 0)
        #expect(file.integer("promptcredentialonce") == 0)
        #expect(file.string("gatewayusername") == "kim")
    }
}
