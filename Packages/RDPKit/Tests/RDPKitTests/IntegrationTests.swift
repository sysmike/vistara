import Foundation
import Testing

@testable import RDPKit

/// Where the integration tests connect, read from the environment. The tests
/// are skipped unless `VISTARA_TEST_RDP_HOST` is set (see scripts/run-test-server.sh).
enum TestHost {
    static let environment = ProcessInfo.processInfo.environment
    static let isConfigured = environment["VISTARA_TEST_RDP_HOST"] != nil

    static var configuration: RDPSessionConfiguration {
        RDPSessionConfiguration(
            host: environment["VISTARA_TEST_RDP_HOST"] ?? "",
            port: UInt16(environment["VISTARA_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: environment["VISTARA_TEST_RDP_USER"] ?? "",
            domain: environment["VISTARA_TEST_RDP_DOMAIN"],
            desktopWidth: 1024,
            desktopHeight: 768
        )
    }

    static func credentials(password: String? = nil) -> RDPCredentials {
        RDPCredentials(
            username: configuration.username,
            domain: configuration.domain,
            password: password ?? environment["VISTARA_TEST_RDP_PASSWORD"] ?? ""
        )
    }

    static func target(password: String? = nil) -> SessionHandle.Target {
        let credentials = credentials(password: password)
        return SessionHandle.Target(
            host: configuration.host,
            port: configuration.port,
            username: credentials.username,
            domain: credentials.domain,
            password: credentials.password
        )
    }

    /// What the test server reported about received input, one entry per
    /// event: "locks 6", "key 1e down", "key 53e up" (e marks extended).
    static func receivedInput() -> [String] {
        guard let path = environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: "vistara-input ") else { return nil }
            var fields: [String: UInt32] = [:]
            for field in line[marker.upperBound...].split(separator: " ") {
                let parts = field.split(separator: "=")
                if parts.count == 2 { fields[String(parts[0])] = UInt32(parts[1].dropFirst(2), radix: 16) }
            }
            guard let flags = fields["flags"] else { return nil }
            guard let code = fields["code"] else { return "locks \(String(flags, radix: 16))" }
            let extended = flags & 0x0100 != 0 ? "e" : ""
            return "key \(String(code, radix: 16))\(extended) \(flags & 0x8000 != 0 ? "up" : "down")"
        }
    }

    /// Answers with the test account and accepts or rejects any certificate.
    static func delegate(password: String? = nil, acceptCertificate: Bool = true) -> RDPSessionDelegate {
        RDPSessionDelegate(
            credentials: { _ in credentials(password: password) },
            certificateDecision: { _ in acceptCertificate }
        )
    }
}

@Suite(.serialized, .enabled(if: TestHost.isConfigured, "Set VISTARA_TEST_RDP_HOST to run"), .timeLimit(.minutes(2)))
struct IntegrationTests {
    // MARK: SessionHandle

    @Test func certificateIsRejectedWhenNobodyDecides() throws {
        let session = try #require(SessionHandle())
        #expect(session.connect(to: TestHost.target()) == .certificateRejected)
        #expect(session.copyFramebuffer() == nil)
    }

    @Test func certificateDetailsReachTheDecider() throws {
        let session = try #require(SessionHandle())
        var seen: [RDPCertificate] = []
        let result = session.connect(to: TestHost.target()) { certificate in
            seen.append(certificate)
            return false
        }

        #expect(result == .certificateRejected)
        let certificate = try #require(seen.first)
        #expect(seen.count == 1)
        #expect(certificate.host == TestHost.configuration.host)
        #expect(certificate.port == TestHost.configuration.port)
        // SHA-256 as colon-separated hex pairs.
        #expect(certificate.fingerprint.split(separator: ":").count == 32)
        #expect(certificate.previousFingerprint == nil)
    }

    @Test func connectsWithNLAAndReceivesAFramebuffer() throws {
        let session = try #require(SessionHandle())
        let result = session.connect(to: TestHost.target()) { _ in true }
        #expect(result == .connected)

        // Give the server up to ten seconds to paint.
        let deadline = Date().addingTimeInterval(10)
        while session.paintCount == 0, Date() < deadline {
            guard session.poll(timeoutMilliseconds: 100) else { break }
        }
        // Let the rest of the first full-screen update arrive.
        for _ in 0..<10 where session.poll(timeoutMilliseconds: 50) {}

        #expect(session.framebufferWidth == 1024)
        #expect(session.framebufferHeight == 768)
        #expect(session.paintCount > 0)

        // The test server shows one solid colour: blue 0x99, green 0x66, red 0x33.
        let pixels = try #require(session.copyFramebuffer())
        #expect(pixels.count == 1024 * 768 * 4)
        #expect(Array(pixels.prefix(3)) == [0x99, 0x66, 0x33])
        #expect(Array(pixels.suffix(4).prefix(3)) == [0x99, 0x66, 0x33])

        session.disconnect()
        #expect(session.copyFramebuffer() == nil)
        #expect(!session.poll(timeoutMilliseconds: 10))
    }

    @Test func wrongPasswordIsAnAuthenticationFailure() throws {
        let session = try #require(SessionHandle())
        let result = session.connect(to: TestHost.target(password: "not the password")) { _ in true }

        #expect(result == .authenticationFailed)
    }

    // MARK: RDPSession

    @Test func sessionReportsEveryStepAndDisconnectsOnRequest() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        let states = await runToEnd(session) { state, session in
            if case .connected = state { session.disconnect() }
        }

        #expect(states.map(\.kind) == [
            "connecting", "awaitingCredentials", "connecting", "awaitingCertificateDecision", "connecting",
            "connected", "disconnected"
        ])
        #expect(states.contains(.connected(width: 1024, height: 768)))
        #expect(states.last == .disconnected(.userRequested))
    }

    @Test func rejectedCertificateEndsTheSession() async {
        let delegate = TestHost.delegate(acceptCertificate: false)
        let states = await runToEnd(RDPSession(configuration: TestHost.configuration, delegate: delegate))

        #expect(states.last == .disconnected(.certificateRejected))
        #expect(!states.map(\.kind).contains("connected"))
    }

    @Test func wrongPasswordEndsTheSession() async {
        let delegate = TestHost.delegate(password: "not the password")
        let states = await runToEnd(RDPSession(configuration: TestHost.configuration, delegate: delegate))

        #expect(states.last == .disconnected(.authenticationFailed))
    }

    @Test func disconnectWhileDecidingOnTheCertificateEndsTheSession() async {
        let delegate = RDPSessionDelegate(
            credentials: { _ in TestHost.credentials() },
            certificateDecision: { _ in
                try? await Task.sleep(for: .seconds(120))
                return true
            }
        )
        let session = RDPSession(configuration: TestHost.configuration, delegate: delegate)
        let states = await runToEnd(session) { state, session in
            if case .awaitingCertificateDecision = state { session.disconnect() }
        }

        #expect(states.last == .disconnected(.userRequested))
        #expect(!states.map(\.kind).contains("connected"))
    }

    @Test func connectsAndDisconnectsFiftyTimes() async {
        for round in 1...50 {
            let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
            let states = await runToEnd(session) { state, session in
                if case .connected = state { session.disconnect() }
            }
            #expect(states.last == .disconnected(.userRequested), "round \(round): \(states.map(\.kind))")
            #expect(states.map(\.kind).contains("connected"), "round \(round)")
        }
    }

    // MARK: Input

    @Test(.enabled(if: TestHost.environment["VISTARA_TEST_SERVER_LOG"] != nil))
    func keysArriveAtTheServerInOrderAsScancodes() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        let keyA = RDPScancode(0x1E)
        // Not connected yet: dropped, not queued for later.
        session.send(RDPInputEvent.tap(keyA))

        let expected = [
            "locks 6", "key 1e down", "key 1e up",
            "key 1d down", "key 38 down", "key 53e down", "key 53e up", "key 38 up", "key 1d up"
        ]
        var received: [String] = []
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            session.send([.lockState([.capsLock, .numLock])] + RDPInputEvent.tap(keyA))
            session.send(RDPInputEvent.controlAltDelete)
            let deadline = Date().addingTimeInterval(10)
            while received.count < expected.count, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                received = TestHost.receivedInput()
            }
            session.disconnect()
        }
        #expect(received == expected)
    }
}
