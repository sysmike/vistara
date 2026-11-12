import Foundation
import Testing

@testable import RDPKit

/// What the test server did with one shared folder, from its log. For each
/// drive it lists the top folder, reads hello.txt, tries to open
/// ..\outside.txt (and reads it, if that opened), and writes from-server.txt.
struct DriveReport {
    var isAnnounced = false
    var listed: [String] = []
    var readStatus: UInt32?
    var readData = Data()
    var escapeStatus: UInt32?
    /// What the server read after its escape opened, if it did.
    var escapeData: Data?
    var writeStatus: UInt32?
    var isDone = false

    static let success: UInt32 = 0
    static let accessDenied: UInt32 = 0xC000_0022

    static func logLines() -> [Substring] {
        guard let path = TestHost.environment["VISTARA_TEST_SERVER_LOG"],
            let log = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return log.split(separator: "\n").filter { $0.contains("vistara-drive ") }
    }

    /// Names of the drives announced in log lines after the first `skipping`.
    static func announcedNames(skipping: Int = 0) -> [String] {
        logLines().dropFirst(skipping).compactMap { line in
            guard line.contains("vistara-drive announced ") else { return nil }
            return fields(of: line)["name"]
        }
    }

    static func fields(of line: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        for word in line.split(separator: " ") {
            let parts = word.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    init(name: String) {
        for line in Self.logLines() {
            let fields = Self.fields(of: line)
            guard fields["name"] == name, let marker = line.range(of: "vistara-drive ") else { continue }
            apply(String(line[marker.upperBound...].prefix { $0 != " " }), fields)
        }
    }

    private mutating func apply(_ event: String, _ fields: [String: String]) {
        let status = fields["status"].flatMap { UInt32($0.dropFirst(2), radix: 16) }
        switch event {
        case "announced": isAnnounced = true
        case "list":
            if let file = fields["file"] { listed.append(file) }
        case "read":
            readStatus = status
            readData = Self.bytes(hex: fields["data"] ?? "")
        case "escape": escapeStatus = status
        case "escape-read": escapeData = Self.bytes(hex: fields["data"] ?? "")
        case "write": writeStatus = status
        case "done": isDone = true
        default: break
        }
    }

    private static func bytes(hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { break }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// Shared folders against the test server.
@Suite(.serialized, .enabled(if: TestHost.isTestServer, "Needs the test server from scripts/run-test-server.sh"),
       .timeLimit(.minutes(2)))
struct DriveIntegrationTests {
    static let helloText = "Hello from the Mac ✓\n"

    /// A folder with hello.txt in it, and outside.txt next to the folder.
    private struct Fixture {
        let name: String
        let folder: URL
        let parent: URL

        init() throws {
            name = "VT" + UUID().uuidString.prefix(6)
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-drive-\(UUID())")
            folder = parent.appendingPathComponent("Shared")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(DriveIntegrationTests.helloText.utf8).write(to: folder.appendingPathComponent("hello.txt"))
            try Data("must stay on the Mac".utf8).write(to: parent.appendingPathComponent("outside.txt"))
        }

        func shared(readOnly: Bool = false) -> RDPSharedFolder {
            RDPSharedFolder(name: name, path: folder.path, isReadOnly: readOnly)
        }

        var writtenByServer: String? {
            try? String(contentsOf: folder.appendingPathComponent("from-server.txt"), encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Connects sharing `folders` and runs until the server is done with all
    /// of them, or `seconds` have passed.
    private func share(_ folders: [RDPSharedFolder], seconds: TimeInterval = 20) throws {
        let handle = try #require(SessionHandle())
        var target = TestHost.target()
        target.sharedFolders = folders
        #expect(handle.connect(to: target) { _ in true } == .connected)
        defer { handle.disconnect() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, handle.poll(timeoutMilliseconds: 100) {
            if !folders.isEmpty, folders.allSatisfy({ DriveReport(name: $0.name).isDone }) { break }
        }
    }

    @Test func theRemoteComputerReadsAndWritesASharedFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try share([fixture.shared()])

        let report = DriveReport(name: fixture.name)
        #expect(report.isDone)
        #expect(report.listed.filter { $0 != "." && $0 != ".." } == ["hello.txt"])
        #expect(report.readStatus == DriveReport.success)
        #expect(String(bytes: report.readData, encoding: .utf8) == Self.helloText)
        #expect(report.writeStatus == DriveReport.success)
        #expect(fixture.writtenByServer == "written by the test server")
    }

    @Test func nothingOutsideTheFolderCanBeReached() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try share([fixture.shared()])

        let report = DriveReport(name: fixture.name)
        #expect(report.isDone)
        // The shim says no, instead of FreeRDP's success without a file.
        #expect(report.escapeStatus == DriveReport.accessDenied)
        #expect(report.escapeData == nil)
    }

    @Test func aReadOnlyFolderCanBeReadButNotChanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let refusedBefore = SessionHandle.refusedDriveRequests
        try share([fixture.shared(readOnly: true)])

        let report = DriveReport(name: fixture.name)
        #expect(report.isDone)
        #expect(report.readStatus == DriveReport.success)
        #expect(String(bytes: report.readData, encoding: .utf8) == Self.helloText)
        #expect(report.writeStatus == DriveReport.accessDenied)
        #expect(report.escapeStatus == DriveReport.accessDenied)
        #expect(fixture.writtenByServer == nil)
        #expect(SessionHandle.refusedDriveRequests > refusedBefore)
    }

    @Test func onlyTheChosenFoldersAreShared() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let before = DriveReport.logLines().count
        try share([first.shared(), second.shared(readOnly: true)])
        #expect(Set(DriveReport.announcedNames(skipping: before)) == [first.name, second.name])
    }

    @Test func withoutFoldersNothingIsShared() throws {
        let before = DriveReport.logLines().count
        try share([], seconds: 3)
        #expect(DriveReport.announcedNames(skipping: before).isEmpty)
    }
}
