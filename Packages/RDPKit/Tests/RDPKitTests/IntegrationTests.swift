import Foundation
import Testing

@testable import RDPKit

/// Where the integration tests connect, read from the environment. The tests
/// are skipped unless `VISTARA_TEST_RDP_HOST` is set (see scripts/run-test-server.sh).
enum TestHost {
    static let environment = ProcessInfo.processInfo.environment
    static let isConfigured = environment["VISTARA_TEST_RDP_HOST"] != nil
    /// The FreeRDP test server from scripts/run-test-server.sh, whose screen,
    /// cursor, and log the tests know. Against any other host, the checks
    /// that depend on them are left out.
    static let isTestServer = environment["VISTARA_TEST_SERVER_LOG"] != nil
    /// Wrong passwords count towards an account lockout on Windows, so tests
    /// that sign in with one run only when this is set.
    static let allowsFailedLogins = environment["VISTARA_TEST_RDP_ALLOW_FAILED_LOGINS"] == "1"
    static let failedLoginsNote: Comment = "Set VISTARA_TEST_RDP_ALLOW_FAILED_LOGINS=1 to sign in with wrong passwords"

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
    /// event, with numbers in hexadecimal: "locks 6", "key 1e down",
    /// "key 53e up" (e marks extended), "mouse 9000 64 32" (flags, x, y),
    /// "xmouse 8001 64 32", and "layout 320 258 64" (width, height, scale).
    static func receivedInput() -> [String] {
        guard let path = environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: "vistara-input ") else { return nil }
            let words = line[marker.upperBound...].split(separator: " ")
            guard let kind = words.first else { return nil }
            var fields: [String: UInt32] = [:]
            for field in words.dropFirst() {
                let parts = field.split(separator: "=")
                if parts.count == 2 { fields[String(parts[0])] = UInt32(parts[1].dropFirst(2), radix: 16) }
            }
            func hex(_ name: String) -> String { String(fields[name] ?? 0, radix: 16) }
            switch kind {
            case "sync":
                return "locks \(hex("flags"))"
            case "layout":
                return "layout \(hex("width")) \(hex("height")) \(hex("scale"))"
            case "key":
                let flags = fields["flags"] ?? 0
                let extended = flags & 0x0100 != 0 ? "e" : ""
                return "key \(hex("code"))\(extended) \(flags & 0x8000 != 0 ? "up" : "down")"
            default:
                return "\(kind) \(hex("flags")) \(hex("x")) \(hex("y"))"
            }
        }
    }

    /// Polls until the server has reported `count` more input events than
    /// `before`, and returns the new ones.
    static func receivedInput(after before: Int, count: Int) -> [String] {
        let deadline = Date().addingTimeInterval(10)
        var received: [String] = []
        while received.count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            received = Array(receivedInput().dropFirst(before))
        }
        return received
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

        let pixels = try #require(session.copyFramebuffer())
        #expect(pixels.count == 1024 * 768 * 4)
        if TestHost.isTestServer {
            // The test server shows one solid colour: blue 0x99, green 0x66, red 0x33.
            #expect(Array(pixels.prefix(3)) == [0x99, 0x66, 0x33])
            #expect(Array(pixels.suffix(4).prefix(3)) == [0x99, 0x66, 0x33])
        }

        session.disconnect()
        #expect(session.copyFramebuffer() == nil)
        #expect(!session.poll(timeoutMilliseconds: 10))
    }

    @Test(.enabled(if: TestHost.allowsFailedLogins, TestHost.failedLoginsNote))
    func wrongPasswordIsAnAuthenticationFailure() throws {
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

    @Test(.enabled(if: TestHost.allowsFailedLogins, TestHost.failedLoginsNote))
    func wrongPasswordEndsTheSession() async {
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

    /// Fifty rounds against the test server; five against a real host, which
    /// may throttle repeated sign-ins.
    @Test func connectsAndDisconnectsRepeatedly() async {
        for round in 1...(TestHost.isTestServer ? 50 : 5) {
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
        let before = TestHost.receivedInput().count
        var received: [String] = []
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            session.send([.lockState([.capsLock, .numLock])] + RDPInputEvent.tap(keyA))
            session.send(RDPInputEvent.controlAltDelete)
            received = TestHost.receivedInput(after: before, count: expected.count)
            session.disconnect()
        }
        #expect(received == expected)
    }

    @Test(.enabled(if: TestHost.environment["VISTARA_TEST_SERVER_LOG"] != nil))
    func pointerInputArrivesAtTheServer() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        // Positions 100, 50 and 300, 200 are 0x64, 0x32 and 0x12c, 0xc8.
        let expected = [
            "mouse 800 64 32",  // move
            "mouse 9000 64 32", "mouse 1000 64 32",  // left down, up
            "mouse a000 64 32", "mouse 2000 64 32",  // right
            "mouse c000 64 32", "mouse 4000 64 32",  // middle
            "xmouse 8001 64 32", "xmouse 1 64 32",  // back
            "xmouse 8002 64 32", "xmouse 2 64 32",  // forward
            "mouse 278 64 32",  // one notch up
            "mouse 3e2 64 32",  // a quarter notch down: -30 in nine bits
            "mouse 478 64 32",  // one notch right
            "mouse 800 12c c8"  // of three moves in a row, only the last
        ]
        let before = TestHost.receivedInput().count
        var received: [String] = []
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            var events: [RDPInputEvent] = [.pointerMove(x: 100, y: 50)]
            for button in RDPPointerButton.allCases {
                events.append(.pointerButton(button, isDown: true, x: 100, y: 50))
                events.append(.pointerButton(button, isDown: false, x: 100, y: 50))
            }
            events += [
                .wheel(.vertical, rotation: 120, x: 100, y: 50),
                .wheel(.vertical, rotation: -30, x: 100, y: 50),
                .wheel(.horizontal, rotation: 120, x: 100, y: 50),
                .pointerMove(x: 10, y: 10), .pointerMove(x: 20, y: 20), .pointerMove(x: 300, y: 200)
            ]
            session.send(events)
            received = TestHost.receivedInput(after: before, count: expected.count)
            session.disconnect()
        }
        #expect(received == expected)
    }

    /// Any cursor from a real host; the exact shape from the test server.
    @Test func theServersCursorArrivesWithItsShape() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        var cursor: RDPCursor?
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            let deadline = Date().addingTimeInterval(10)
            while cursor == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                cursor = session.framebuffer.takeCursor()
            }
            session.disconnect()
        }
        #expect(cursor != nil, "the server set no cursor")
        guard TestHost.isTestServer else { return }
        guard case .image(let shape) = cursor else {
            Issue.record("expected a cursor image, got \(String(describing: cursor))")
            return
        }
        // The test server's cursor: 16x8, hot spot 3, 5, one colour, and a
        // transparent pixel in the top left corner.
        #expect(shape.width == 16)
        #expect(shape.height == 8)
        #expect(shape.hotspotX == 3)
        #expect(shape.hotspotY == 5)
        #expect(shape.pixels.count == 16 * 8 * 4)
        let bytes = [UInt8](shape.pixels)
        #expect(bytes.count >= 8 && bytes[3] == 0)
        #expect(bytes.count >= 8 && Array(bytes[4..<8]) == [0x50, 0xC0, 0x10, 0xFF])
        #expect(Array(bytes.suffix(4)) == [0x50, 0xC0, 0x10, 0xFF])
    }

    // MARK: Desktop size

    @Test(.enabled(if: TestHost.environment["VISTARA_TEST_SERVER_LOG"] != nil))
    func theDesktopChangesSizeOnRequestWithoutReconnecting() async {
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        let before = TestHost.receivedInput().count
        var requests: [String] = []
        var resized = (width: 0, height: 0)
        var restored = (width: 0, height: 0)

        /// Waits until the framebuffer has the given size.
        func waitForSize(_ width: Int, _ height: Int) -> (width: Int, height: Int) {
            let deadline = Date().addingTimeInterval(10)
            while session.framebuffer.size != (width, height), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return session.framebuffer.size
        }

        let states = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            _ = waitForSize(1024, 768)
            // Two requests at once: only the second is worth sending.
            session.send([
                .desktopSize(width: 640, height: 480, scalePercent: 100),
                .desktopSize(width: 800, height: 600, scalePercent: 200)
            ])
            resized = waitForSize(800, 600)
            requests = TestHost.receivedInput(after: before, count: 1)

            // Back to the size the other tests expect.
            session.send([.desktopSize(width: 1024, height: 768, scalePercent: 100)])
            restored = waitForSize(1024, 768)
            session.disconnect()
        }

        #expect(requests == ["layout 320 258 c8"])
        #expect(resized.width == 800 && resized.height == 600)
        #expect(restored.width == 1024 && restored.height == 768)
        // One connection throughout: connected once, and ended by us.
        #expect(states.filter { $0.kind == "connected" }.count == 1)
        #expect(states.last == .disconnected(.userRequested))
    }
}
