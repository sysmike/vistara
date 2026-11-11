import Foundation
import Testing

@testable import RDPKit

@Test func linkedFreeRDPMatchesThePinnedVersion() throws {
    let pinFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // RDPKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // RDPKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("FREERDP_VERSION")
    let pin = try String(contentsOf: pinFile, encoding: .utf8)
    let pinnedVersion = try #require(pin.split(separator: " ").first)

    #expect(RDPKit.freeRDPVersion == String(pinnedVersion))
}

@Test func createsAndFreesAFreeRDPContext() {
    for _ in 0..<10 {
        #expect(SessionHandle() != nil)
    }
}
