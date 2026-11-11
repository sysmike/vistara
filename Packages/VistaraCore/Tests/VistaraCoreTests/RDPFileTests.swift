import Foundation
import Testing

@testable import VistaraCore

/// Modelled on a file saved by the Microsoft client, shortened.
private let sampleText = """
    screen mode id:i:2
    use multimon:i:0
    desktopwidth:i:1920
    desktopheight:i:1080
    session bpp:i:32
    full address:s:build01.example.com:3390
    audiomode:i:2
    redirectclipboard:i:0
    autoreconnection enabled:i:1
    authentication level:i:2
    enablecredsspsupport:i:1
    username:s:EXAMPLE\\alice
    drivestoredirect:s:C:\\;D:\\
    password 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB
    """

@Test func parsesKeyTypeValueLines() {
    let file = RDPFile(text: sampleText)
    #expect(file.settings.count == 13)
    #expect(file.skippedLines.isEmpty)
    #expect(file.integer("desktopwidth") == 1920)
    #expect(file.string("full address") == "build01.example.com:3390")
    #expect(file.string("drivestoredirect") == "C:\\;D:\\")
}

@Test func keysAreCaseInsensitive() {
    let file = RDPFile(text: "Full Address:S:host\nDesktopWidth:I:800")
    #expect(file.string("full address") == "host")
    #expect(file.integer("DESKTOPWIDTH") == 800)
}

@Test func malformedLinesAreSkippedAndReported() {
    let file = RDPFile(text: "full address:s:host\nnot a setting\ndesktopwidth:i:wide\nkey:x:1\n:s:empty key\n\n")
    #expect(file.settings == [.init(key: "full address", value: .string("host"))])
    #expect(file.skippedLines == ["not a setting", "desktopwidth:i:wide", "key:x:1", ":s:empty key"])
}

@Test func passwordsAreDiscardedOnParse() {
    let file = RDPFile(text: sampleText + "\ngatewaypassword:s:hunter2")
    #expect(file.droppedPassword)
    #expect(!file.settings.contains { $0.key.contains("password") })
    #expect(!file.text.contains("hunter2"))
    #expect(!file.text.contains("01000000D08C"))
}

@Test func filesWithoutAPasswordDoNotReportOne() {
    #expect(!RDPFile(text: "full address:s:host").droppedPassword)
}

@Test func readsUTF16WithByteOrderMarkAndWindowsLineEndings() throws {
    let text = "full address:s:höst.example.com\r\ndesktopwidth:i:1280\r\n"
    var littleEndian = Data([0xFF, 0xFE])
    littleEndian.append(try #require(text.data(using: .utf16LittleEndian)))
    var bigEndian = Data([0xFE, 0xFF])
    bigEndian.append(try #require(text.data(using: .utf16BigEndian)))

    for data in [littleEndian, bigEndian] {
        let file = try RDPFile(data: data)
        #expect(file.string("full address") == "höst.example.com")
        #expect(file.integer("desktopwidth") == 1280)
    }
}

@Test func readsUTF8WithAndWithoutByteOrderMark() throws {
    let text = "full address:s:höst.example.com\n"
    let plain = Data(text.utf8)
    #expect(try RDPFile(data: plain).string("full address") == "höst.example.com")
    #expect(try RDPFile(data: Data([0xEF, 0xBB, 0xBF]) + plain).string("full address") == "höst.example.com")
}

@Test func writtenDataReadsBack() throws {
    let file = RDPFile(text: sampleText)
    let data = file.data
    #expect(data.prefix(2) == Data([0xFF, 0xFE]))
    #expect(try RDPFile(data: data).settings == file.settings)
}

@Test func importMapsKnownSettings() throws {
    let connection = try RDPFileMapping.connection(from: RDPFile(text: sampleText), name: "Build Server")
    #expect(connection.name == "Build Server")
    #expect(connection.host == "build01.example.com")
    #expect(connection.port == 3390)
    #expect(connection.username == "alice")
    #expect(connection.domain == "EXAMPLE")
    #expect(connection.resolutionMode == .fixed)
    #expect(connection.fixedWidth == 1920)
    #expect(connection.fixedHeight == 1080)
    #expect(connection.audioMode == .off)
    #expect(!connection.sharesClipboard)
    #expect(connection.reconnectsAutomatically)
    #expect(connection.requiresNLA)
    #expect(connection.certificatePolicy == .askOnFirstUse)
    #expect(connection.additionalRDPSettings == [
        "screen mode id:i:2", "use multimon:i:0", "session bpp:i:32", "drivestoredirect:s:C:\\;D:\\"
    ])
}

@Test func importNeverTurnsCertificateChecksOff() throws {
    for level in [0, 2, 3] {
        let file = RDPFile(text: "full address:s:host\nauthentication level:i:\(level)")
        #expect(try RDPFileMapping.connection(from: file, name: "A").certificatePolicy == .askOnFirstUse)
    }
    let strict = RDPFile(text: "full address:s:host\nauthentication level:i:1")
    #expect(try RDPFileMapping.connection(from: strict, name: "A").certificatePolicy == .requireTrusted)
}

@Test func importWithoutAnAddressFails() {
    #expect(throws: RDPFileMapping.ImportError.missingAddress) {
        try RDPFileMapping.connection(from: RDPFile(text: "desktopwidth:i:800"), name: "A")
    }
}

@Test func addressesSplitIntoHostAndPort() {
    let expectations: [String: String] = [
        "host": "host|nil",
        "host:3390": "host|3390",
        "[fe80::1]:3390": "fe80::1|3390",
        "[fe80::1]": "fe80::1|nil",
        "fe80::1": "fe80::1|nil"
    ]
    for (address, expected) in expectations {
        let result = RDPFileMapping.splitAddress(address)
        #expect("\(result.host)|\(result.port.map(String.init) ?? "nil")" == expected)
    }
    #expect(RDPFileMapping.joinAddress(host: "host", port: 3389) == "host")
    #expect(RDPFileMapping.joinAddress(host: "host", port: 3390) == "host:3390")
    #expect(RDPFileMapping.joinAddress(host: "fe80::1", port: 3390) == "[fe80::1]:3390")
}

@Test func exportThenImportGivesTheSameConnection() throws {
    var connection = Connection(name: "Lab", host: "fe80::1")
    connection.port = 3390
    connection.username = "bob"
    connection.domain = "LAB"
    connection.resolutionMode = .scaleToFit
    connection.usesHiDPI = false
    connection.sharesClipboard = false
    connection.audioMode = .playOnRemote
    connection.reconnectsAutomatically = false
    connection.requiresNLA = false
    connection.certificatePolicy = .requireTrusted
    connection.additionalRDPSettings = ["use multimon:i:0"]

    let file = try RDPFile(data: RDPFileMapping.file(from: connection).data)
    var imported = try RDPFileMapping.connection(from: file, name: "Lab")
    imported.id = connection.id
    #expect(imported == connection)
}

@Test func exportNeverContainsAPassword() {
    var connection = Connection(name: "A", host: "host")
    connection.additionalRDPSettings = ["password 51:b:DEADBEEF", "gatewaypassword:s:hunter2", "use multimon:i:0"]

    let file = RDPFileMapping.file(from: connection)
    #expect(!file.text.lowercased().contains("password"))
    #expect(!file.text.contains("hunter2"))
    #expect(file.integer("use multimon") == 0)
}
