import AppKit
import Foundation
import RDPKit
import RDPKitUI
import Testing
import VistaraCore
@testable import Vistara

/// The gateway in the connection editor, the session, and imports
/// (docs/DESIGN.md, RD Gateway; #123).
@Suite
@MainActor
struct GatewayEditingTests {
    private static let gateway = Connection.Gateway(
        usage: .always, host: "gateway.example.com", port: 8443, signIn: .anotherAccount, username: "kim",
        domain: "CORP"
    )

    private func draft(_ address: String) -> ConnectionDraft {
        var draft = ConnectionDraft()
        draft.host = "build01"
        draft.gatewayUsage = .always
        draft.gatewayAddress = address
        return draft
    }

    @Test
    func theGatewayGoesFromTheConnectionToTheEditorAndBack() throws {
        var connection = Connection(name: "Build Server", host: "build01")
        connection.gateway = Self.gateway
        let draft = ConnectionDraft(connection)
        #expect(draft.gatewayAddress == "gateway.example.com:8443")
        #expect(try #require(draft.connection()).gateway == Self.gateway)
    }

    @Test
    func aNewConnectionUsesNoGateway() throws {
        var draft = ConnectionDraft()
        draft.host = "build01"
        #expect(draft.gatewayUsage == .never)
        #expect(draft.gatewayProblem == nil)
        #expect(try #require(draft.connection()).gateway == Connection.Gateway())
    }

    @Test
    func theAddressSaysWhatIsWrongWithIt() {
        #expect(draft("").gatewayProblem == "Enter the gateway’s name or address.")
        #expect(draft("https://gw.example.com").gatewayProblem?.contains("“https://”") == true)
        #expect(draft("gw example").gatewayProblem == "A gateway’s name can’t contain spaces.")
        #expect(draft("gw:0").gatewayProblem == "Enter a port from 1 to 65535 after the colon.")
        #expect(draft("gw:https").gatewayProblem == "Enter a port from 1 to 65535 after the colon.")
        #expect(!draft("").isValid)
        for good in ["gw", "gw:8443", "10.0.0.1", "[fd00::1]:8443", "fd00::1"] {
            #expect(draft(good).gatewayProblem == nil, "\(good)")
        }
        #expect(draft(" gw:8443 ").gateway.port == 8443)
        #expect(draft("gw").gateway.port == 443)
    }

    /// Never hides the rest but keeps it, so switching back finds it again.
    @Test
    func neverKeepsWhatWasTyped() throws {
        var draft = draft("gw.example.com")
        draft.gatewayUsage = .never
        draft.gatewayAddress = "gw.example.com:not a port"
        #expect(draft.gatewayProblem == nil)
        draft.gatewayAddress = "gw.example.com"
        let gateway = try #require(draft.connection()).gateway
        #expect(gateway.usage == .never)
        #expect(gateway.host == "gw.example.com")
    }

    @Test
    func aUserTypedWithItsDomainIsSplit() throws {
        var draft = draft("gw")
        draft.gatewaySignIn = .anotherAccount
        draft.gatewayUsername = "CORP\\kim"
        let gateway = try #require(draft.connection()).gateway
        #expect(gateway.username == "kim")
        #expect(gateway.domain == "CORP")
    }

    @Test
    func aSessionGoesThroughTheGatewayOnlyWhenItIsUsed() {
        var connection = Connection(name: "Build Server", host: "build01")
        #expect(SessionTarget(connection: connection).gateway == nil)
        connection.gateway = Self.gateway
        let desktop = DesktopSize(width: 1280, height: 800, scalePercent: 100)
        let configured = SessionTarget(connection: connection).configuration(desktop: desktop).gateway
        #expect(configured == RDPGateway(
            host: "gateway.example.com", port: 8443, signIn: .ownAccount(username: "kim", domain: "CORP")
        ))
        connection.gateway.signIn = .sameAsComputer
        let same = SessionTarget(connection: connection).configuration(desktop: desktop).gateway
        #expect(same?.signIn == .sameAsComputer)
        connection.gateway.usage = .never
        #expect(SessionTarget(connection: connection).configuration(desktop: desktop).gateway == nil)
    }

    @Test
    func theImportNoticeSaysWhenAGatewayIsUsedAlways() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Office PC.rdp")
        try Data("full address:s:office\ngatewayhostname:s:gw.example.com\ngatewayusagemethod:i:2\n".utf8)
            .write(to: url)
        let (model, _) = try await temporaryLibrary()

        let report = await model.importRDPFiles([url])
        #expect(report.gatewaysUsedAlways == ["Office PC"])
        #expect(report.sentences.contains("“Office PC” uses its gateway only when needed; Vistara always uses it."))
        #expect(model.library.connections.first?.gateway.usage == .always)
    }

    @Test(arguments: [false, true])
    func screenshotOfTheEditorWithAGateway(dark: Bool) async throws {
        var connection = SampleLibrary.library.connections[0]
        connection.gateway = Self.gateway
        let view = ConnectionEditor(draft: ConnectionDraft(connection), folders: []) { _ in }
        let name = dark ? "editor-gateway-dark" : "editor-gateway"
        let bytes = try await Screenshots.write(view, size: NSSize(width: 480, height: 700), name: name, dark: dark)
        #expect(bytes > 0)
    }
}
