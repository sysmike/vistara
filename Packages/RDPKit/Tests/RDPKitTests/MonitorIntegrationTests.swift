import Foundation
import Testing

@testable import RDPKit

/// Several monitors as RDPKit describes them (#110).
@Suite
struct RDPMonitorTests {
    @Test func theDesktopIsTheMonitorsBoundingBox() {
        let monitors = [
            RDPMonitor(x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
            RDPMonitor(x: -1280, y: -200, width: 1280, height: 1024, isPrimary: false)
        ]
        let box = RDPMonitor.boundingBox(of: monitors)
        #expect(box == RDPFramebuffer.Rect(x: -1280, y: -200, width: 3200, height: 1280))
        // In the framebuffer, the top left of the box is the origin.
        #expect(monitors[0].framebufferRect(in: box) == RDPFramebuffer.Rect(x: 1280, y: 200, width: 1920, height: 1080))
        #expect(monitors[1].framebufferRect(in: box) == RDPFramebuffer.Rect(x: 0, y: 0, width: 1280, height: 1024))
        #expect(RDPMonitor.boundingBox(of: []).width == 0)
    }

    @Test func aLayoutAndASizeReplaceEachOtherWhileTheyWait() {
        let layout = RDPInputEvent.monitorLayout([RDPMonitor(x: 0, y: 0, width: 800, height: 600, isPrimary: true)])
        let size = RDPInputEvent.desktopSize(width: 1024, height: 768, scalePercent: 100)
        #expect(layout.isSuperseded(by: size))
        #expect(size.isSuperseded(by: layout))
        #expect(layout.isSuperseded(by: layout))
        #expect(!layout.isSuperseded(by: .displayUpdates(true)))
    }
}

/// The test server logs each monitor it is told about, when a client connects
/// and through Display Control.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(1)))
struct MonitorIntegrationTests {
    static let primary = RDPMonitor(x: 0, y: 0, width: 1024, height: 768, isPrimary: true)

    static func monitorsTheServerSaw(via channel: String) -> [String] {
        guard let path = TestHost.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        let marker = "vistara-monitor via=\(channel) "
        return log.split(separator: "\n").compactMap { line in
            line.range(of: marker).map { String(line[$0.upperBound...]) }
        }
    }

    /// Waits until the framebuffer has the given size, and returns the size it has.
    static func waitForSize(_ session: RDPSession, _ width: Int, _ height: Int) -> (width: Int, height: Int) {
        let deadline = Date().addingTimeInterval(10)
        while session.framebuffer.size != (width, height), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return session.framebuffer.size
    }

    @Test func aTwoMonitorConnectionArrivesAsTwoMonitors() async {
        let before = Self.monitorsTheServerSaw(via: "connect").count
        var configuration = TestHost.configuration
        configuration.monitors = [Self.primary, RDPMonitor(x: 1024, y: 0, width: 800, height: 600, isPrimary: false)]
        let session = RDPSession(configuration: configuration, delegate: TestHost.delegate())
        let states = await runToEnd(session) { state, session in
            if case .connected = state { session.disconnect() }
        }
        #expect(states.contains { $0.kind == "connected" })
        let seen = Self.monitorsTheServerSaw(via: "connect").dropFirst(before)
        #expect(seen.contains("index=0 left=0 top=0 width=1024 height=768 primary=1 scale=100"), "\(seen)")
        #expect(seen.contains("index=1 left=1024 top=0 width=800 height=600 primary=0 scale=100"), "\(seen)")
    }

    @Test func aSingleMonitorConnectionAnnouncesNoMonitors() async {
        let before = Self.monitorsTheServerSaw(via: "connect").count
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        _ = await runToEnd(session) { state, session in
            if case .connected = state { session.disconnect() }
        }
        #expect(Self.monitorsTheServerSaw(via: "connect").count == before)
    }
}

/// In the serialized suite that also resizes the test server's screen, so
/// that the two never overlap.
extension IntegrationTests {
    /// A monitor to the left of the primary: the desktop becomes their
    /// bounding box. Restored afterwards, as other tests expect 1024 x 768.
    @Test(.enabled(if: TestHost.isTestServer, "Reads the test server's log"))
    func aLayoutChangeArrivesThroughDisplayControl() async {
        let before = MonitorIntegrationTests.monitorsTheServerSaw(via: "display-control").count
        let session = RDPSession(configuration: TestHost.configuration, delegate: TestHost.delegate())
        var resized = (width: 0, height: 0)
        _ = await runToEnd(session) { state, session in
            guard case .connected = state else { return }
            _ = MonitorIntegrationTests.waitForSize(session, 1024, 768)
            let left = RDPMonitor(x: -800, y: 0, width: 800, height: 600, isPrimary: false, scalePercent: 200)
            session.send([.monitorLayout([MonitorIntegrationTests.primary, left])])
            resized = MonitorIntegrationTests.waitForSize(session, 1824, 768)
            session.send([.desktopSize(width: 1024, height: 768, scalePercent: 100)])
            _ = MonitorIntegrationTests.waitForSize(session, 1024, 768)
            session.disconnect()
        }
        let seen = MonitorIntegrationTests.monitorsTheServerSaw(via: "display-control").dropFirst(before)
        #expect(seen.contains("index=0 left=0 top=0 width=1024 height=768 primary=1 scale=100"), "\(seen)")
        #expect(seen.contains("index=1 left=-800 top=0 width=800 height=600 primary=0 scale=200"), "\(seen)")
        #expect(resized.width == 1824 && resized.height == 768)
    }
}
