import Foundation
import Testing

@testable import VistaraCore

@Suite
struct CertificateTrustStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vistara-trust-\(UUID().uuidString)", isDirectory: true)
    private let first = "3f:9a:11:c4:5e:7b:02:d8:66:1a:90:ef:4c:33:b7:25"
        + ":8d:e1:0f:72:a4:5b:c9:16:e8:30:7d:94:2b:6f:ac:51"
    private let second = "a1:07:5c:de:42:90:3b:f8:19:c6:7e:05:d3:68:2a:b4"
        + ":91:0c:e7:36:5f:a8:14:7b:c0:29:e5:83:4d:f1:6a:9e"

    private var fileURL: URL { directory.appendingPathComponent(CertificateTrustStore.fileName) }

    private func makeStore() -> CertificateTrustStore {
        CertificateTrustStore(directory: directory)
    }

    private func writeFile(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    @Test func aComputerSeenForTheFirstTimeIsUnknown() {
        let store = makeStore()
        #expect(store.trust(forHost: "build01", port: 3389, fingerprint: first) == .unknown)
        #expect(store.certificates.isEmpty)
        // Asking writes nothing.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func aTrustedCertificateMatchesAcrossRestartsAndSpelling() throws {
        try makeStore().add(host: "Build01.Example.com", port: 3389, fingerprint: first.uppercased())

        let store = makeStore()
        #expect(store.trust(forHost: "build01.example.com", port: 3389, fingerprint: first) == .trusted)
        #expect(store.trust(forHost: "BUILD01.example.com", port: 3389, fingerprint: first.uppercased()) == .trusted)
        #expect(store.certificates.map(\.host) == ["build01.example.com"])
    }

    @Test func anotherCertificateForTheSameComputerIsAChange() throws {
        let store = makeStore()
        try store.add(host: "build01", port: 3389, fingerprint: first)
        #expect(store.trust(forHost: "build01", port: 3389, fingerprint: second)
            == .changed(previousFingerprint: first))
        // Asking does not replace what is trusted.
        #expect(store.trust(forHost: "build01", port: 3389, fingerprint: first) == .trusted)
    }

    @Test func hostAndPortTogetherIdentifyAComputer() throws {
        let store = makeStore()
        try store.add(host: "build01", port: 3389, fingerprint: first)
        #expect(store.trust(forHost: "build01", port: 3390, fingerprint: first) == .unknown)
        #expect(store.trust(forHost: "build02", port: 3389, fingerprint: first) == .unknown)
    }

    @Test func addingAgainReplaces() throws {
        let store = makeStore()
        try store.add(host: "build01", port: 3389, fingerprint: first)
        try store.add(host: "build01", port: 3389, fingerprint: second)
        #expect(store.certificates.count == 1)
        #expect(makeStore().trust(forHost: "build01", port: 3389, fingerprint: second) == .trusted)
    }

    @Test func aRemovedCertificateIsUnknownAgain() throws {
        let store = makeStore()
        try store.add(host: "build01", port: 3389, fingerprint: first)
        try store.add(host: "build02", port: 3389, fingerprint: second)
        try store.remove(host: "BUILD01", port: 3389)
        try store.remove(host: "never-there", port: 3389)

        let reopened = makeStore()
        #expect(reopened.trust(forHost: "build01", port: 3389, fingerprint: first) == .unknown)
        #expect(reopened.trust(forHost: "build02", port: 3389, fingerprint: second) == .trusted)
    }

    @Test func aCorruptFileIsMovedAsideAndNothingIsTrusted() throws {
        try makeStore().add(host: "build01", port: 3389, fingerprint: first)
        try writeFile("{ this is not JSON")

        let store = makeStore()
        #expect(store.trust(forHost: "build01", port: 3389, fingerprint: first) == .unknown)
        let backup = try #require(store.corruptFileBackup)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // The store works again afterwards.
        try store.add(host: "build01", port: 3389, fingerprint: second)
        #expect(makeStore().trust(forHost: "build01", port: 3389, fingerprint: second) == .trusted)
    }

    @Test func aFileOfTheWrongShapeCountsAsCorrupt() throws {
        try writeFile(#"{"schemaVersion": 1, "certificates": "all of them"}"#)
        let store = makeStore()
        #expect(store.certificates.isEmpty)
        #expect(store.corruptFileBackup != nil)
    }

    @Test func aFileFromANewerVersionIsLeftAloneAndTrustsNothing() throws {
        let newer = #"{"schemaVersion": 2, "certificates": [], "somethingNew": true}"#
        try writeFile(newer)

        let store = makeStore()
        #expect(store.trust(forHost: "build01", port: 3389, fingerprint: first) == .unknown)
        #expect(throws: CertificateTrustStore.StoreError.newerSchema(found: 2)) {
            try store.add(host: "build01", port: 3389, fingerprint: first)
        }
        #expect(store.corruptFileBackup == nil)
        try #expect(String(contentsOf: fileURL, encoding: .utf8) == newer)
    }

    @Test func theFileHoldsFingerprintsOnlyAndIsPrivate() throws {
        try makeStore().add(host: "build01", port: 3389, fingerprint: first)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(text.contains(first))
        #expect(!text.contains("BEGIN CERTIFICATE"))

        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
        #expect(permissions as? NSNumber == 0o600)
    }
}
