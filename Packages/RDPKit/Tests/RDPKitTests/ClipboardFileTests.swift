import Foundation
import Testing

@testable import RDPKit

/// A new folder for one test, with helpers to fill it. Removed by `remove()`.
struct ScratchFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vistara-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ path: String, _ contents: Data) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: file)
        return file
    }

    @discardableResult
    func file(_ path: String, _ text: String) throws -> URL {
        try file(path, Data(text.utf8))
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A symbolic link at `path` to `destination`, as written.
    @discardableResult
    func link(_ path: String, to destination: String) throws -> URL {
        let link = url.appendingPathComponent(path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return link
    }
}

/// One entry of a packed file list ([MS-RDPECLIP] 2.2.5.2.3.1), as a remote
/// computer could send it.
func fileDescriptor(_ name: String, isFolder: Bool = false, size: UInt64? = 0) -> Data {
    var data = Data()
    func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let attributes: UInt32 = 0x4  // FD_ATTRIBUTES
    append(attributes | (size == nil ? 0 : 0x40))  // FD_FILESIZE
    data.append(Data(count: 16 + 8 + 8))  // clsid, sizel, pointl
    append(isFolder ? 0x10 : 0x80)  // FILE_ATTRIBUTE_DIRECTORY or _NORMAL
    data.append(Data(count: 24))  // creation, access, and write times
    append(UInt32((size ?? 0) >> 32))
    append(UInt32((size ?? 0) & 0xFFFF_FFFF))
    var name = Array(name.utf16.prefix(259))
    name += Array(repeating: 0, count: 260 - name.count)
    for unit in name { withUnsafeBytes(of: unit.littleEndian) { data.append(contentsOf: $0) } }
    return data
}

func fileList(_ descriptors: [Data]) -> Data {
    var data = Data()
    withUnsafeBytes(of: UInt32(descriptors.count).littleEndian) { data.append(contentsOf: $0) }
    descriptors.forEach { data.append($0) }
    return data
}

@Suite
struct ClipboardFileTests {
    @Test func aFolderBringsEverythingInItWithSizes() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let report = try scratch.file("Report.txt", "Quarterly report\n")
        try scratch.file("Folder/Inner.txt", "Inside\n")
        try scratch.file("Folder/Sub/Deep.bin", Data(count: 1000))
        try scratch.folder("Folder/Empty")

        let offer = RDPLocalFileOffer(urls: [report, scratch.url.appendingPathComponent("Folder")])

        #expect(
            offer.files == [
                RDPClipboardFile(path: "Report.txt", size: 17, isFolder: false),
                RDPClipboardFile(path: "Folder", size: 0, isFolder: true),
                RDPClipboardFile(path: "Folder/Empty", size: 0, isFolder: true),
                RDPClipboardFile(path: "Folder/Inner.txt", size: 7, isFolder: false),
                RDPClipboardFile(path: "Folder/Sub", size: 0, isFolder: true),
                RDPClipboardFile(path: "Folder/Sub/Deep.bin", size: 1000, isFolder: false)
            ]
        )
        #expect(offer.skippedCount == 0)
        #expect(offer.files.filter(\.isTopLevel).map(\.path) == ["Report.txt", "Folder"])
    }

    @Test func symbolicLinksAreLeftOutEverywhere() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.file("Folder/Real.txt", "real\n")
        try scratch.link("Folder/Link.txt", to: "Real.txt")
        try scratch.file("Outside/Secret.txt", "secret\n")
        try scratch.link("Folder/Linked Folder", to: "../Outside")
        let top = try scratch.link("Top.txt", to: "Folder/Real.txt")

        let offer = RDPLocalFileOffer(urls: [scratch.url.appendingPathComponent("Folder"), top])

        #expect(offer.files.map(\.path) == ["Folder", "Folder/Real.txt"])
        #expect(offer.skippedCount == 3)
    }

    @Test func namesWindowsDoesNotAllowAreEscaped() throws {
        #expect(RDPClipboardFileName.toRemote("a:b?.txt") == "a_b_.txt")
        #expect(RDPClipboardFileName.toRemote("<quoted> \"x\"|y*") == "_quoted_ _x__y_")
        #expect(RDPClipboardFileName.toRemote("back\\slash") == "back_slash")
        #expect(RDPClipboardFileName.toRemote("trailing.") == "trailing_")
        #expect(RDPClipboardFileName.toRemote("trailing ") == "trailing_")
        #expect(RDPClipboardFileName.toRemote("tab\there") == "tab_here")
        #expect(RDPClipboardFileName.toRemote("CON.txt") == "_CON.txt")
        #expect(RDPClipboardFileName.toRemote("lpt1") == "_lpt1")
        #expect(RDPClipboardFileName.toRemote("CONSOLE.txt") == "CONSOLE.txt")
        #expect(RDPClipboardFileName.toRemote("Grüße ✓.txt") == "Grüße ✓.txt")

        // On disk: a ":" (shown as "/" in the Finder), and characters a URL escapes.
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let colon = try scratch.file("Q1:Q2.txt", "x")
        let escaped = try scratch.file("100% done #1 Grüße.txt", "x")
        let offer = RDPLocalFileOffer(urls: [colon, escaped])
        #expect(offer.files.map(\.path) == ["Q1_Q2.txt", "100% done #1 Grüße.txt"])
    }

    @Test func pathsTooLongForWindowsAreLeftOut() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let long = String(repeating: "f", count: 200)
        try scratch.file("\(long)/\(String(repeating: "n", count: 58)).txt", "too long\n")
        try scratch.file("\(long)/\(String(repeating: "n", count: 59)).txt", "too long\n")

        let offer = RDPLocalFileOffer(urls: [scratch.url.appendingPathComponent(long)])

        // 200 + 1 + 58 + 4 = 263 units would not fit; 200 + 1 + 54 + 4 = 259 does.
        #expect(offer.files.count == 1)
        #expect(offer.skippedCount == 2)
        let fits = String(repeating: "n", count: 54)
        try scratch.file("\(long)/\(fits).txt", "fits\n")
        let again = RDPLocalFileOffer(urls: [scratch.url.appendingPathComponent(long)])
        #expect(again.files.map(\.path).last == "\(long)/\(fits).txt")
    }

    @Test func remoteNamesBecomePathsBelowTheFolder() {
        #expect(RDPClipboardFileName.fromRemote("Report.txt") == "Report.txt")
        #expect(RDPClipboardFileName.fromRemote("Folder\\Inner.txt") == "Folder/Inner.txt")
        // A "/" in a Windows name stays part of the name, as the Finder shows ":".
        #expect(RDPClipboardFileName.fromRemote("Folder\\Q1/Q2.txt") == "Folder/Q1:Q2.txt")
        #expect(RDPClipboardFileName.fromRemote("Grüße ✓.txt") == "Grüße ✓.txt")
        // Nothing that could land outside the folder.
        #expect(RDPClipboardFileName.fromRemote("\\Absolute.txt") == nil)
        #expect(RDPClipboardFileName.fromRemote("Folder\\\\Inner.txt") == nil)
        #expect(RDPClipboardFileName.fromRemote("..\\Outside.txt") == nil)
        #expect(RDPClipboardFileName.fromRemote("Folder\\.\\Inner.txt") == nil)
        #expect(RDPClipboardFileName.fromRemote("/..") == ":..")
        #expect(RDPClipboardFileName.fromRemote("") == nil)
        #expect(RDPClipboardFileName.fromRemote(String(repeating: "ü", count: 128)) == nil)
    }

    @Test func aListGoesToTheRemoteComputerAndComesBackTheSame() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.file("Folder/Grüße ✓.txt", "Hallo\n")
        try scratch.file("Folder/a:b.txt", "colon\n")
        try scratch.folder("Folder/Empty")
        let large = try scratch.file("Large.bin", Data(count: 70_000))
        let offer = RDPLocalFileOffer(urls: [scratch.url.appendingPathComponent("Folder"), large])

        let encoded = try #require(SessionHandle.encodeFileList(offer))
        let decoded = try #require(SessionHandle.decodeFileList(encoded))

        // A count, then 592 bytes for each entry.
        #expect(encoded.count == 4 + 592 * offer.files.count)
        #expect(decoded.files == offer.files)
        #expect(
            decoded.files.map(\.path) == ["Folder", "Folder/Empty", "Folder/Grüße ✓.txt", "Folder/a_b.txt", "Large.bin"]
        )
        #expect(decoded.skippedCount == 0)
    }

    @Test func aRemoteListKeepsWhatCanBeUsedOnTheMac() throws {
        let list = fileList([
            fileDescriptor("Report.bin", size: 5_000_000_000),
            fileDescriptor("\\Absolute.txt", size: 3),
            fileDescriptor("Folder", isFolder: true),
            fileDescriptor("Folder\\Unsized.txt", size: nil)
        ])

        let decoded = try #require(SessionHandle.decodeFileList(list))

        #expect(
            decoded.files == [
                RDPClipboardFile(path: "Report.bin", size: 5_000_000_000, isFolder: false),
                RDPClipboardFile(path: "Folder", size: 0, isFolder: true),
                RDPClipboardFile(path: "Folder/Unsized.txt", size: 0, isFolder: false)
            ]
        )
        #expect(decoded.listIndices == [0, 2, 3])
        #expect(decoded.skippedCount == 1)
    }

    @Test func aRemoteListWithAPathOutOfTheFolderIsRefusedWhole() {
        // FreeRDP refuses the list as soon as one name climbs out with "..".
        let list = fileList([fileDescriptor("Fine.txt", size: 1), fileDescriptor("..\\Outside.txt", size: 1)])
        #expect(SessionHandle.decodeFileList(list) == nil)
        #expect(SessionHandle.decodeFileList(Data([1, 0, 0, 0, 7])) == nil)
    }

    @Test func fetchingAFolderBringsEverythingInIt() {
        let list = RDPRemoteFiles(
            files: [
                RDPClipboardFile(path: "Report.bin", size: 10, isFolder: false),
                RDPClipboardFile(path: "Folder", size: 0, isFolder: true),
                RDPClipboardFile(path: "Folder/a.txt", size: 1, isFolder: false),
                RDPClipboardFile(path: "Folder/Sub", size: 0, isFolder: true),
                RDPClipboardFile(path: "Folder/Sub/b.txt", size: 2, isFolder: false),
                RDPClipboardFile(path: "Folder Two", size: 0, isFolder: true)
            ],
            skippedCount: 1, listID: 7, listIndices: [0, 1, 2, 4, 5, 6]
        )
        #expect(list.topLevel.map(\.path) == ["Report.bin", "Folder", "Folder Two"])

        let plan = RDPFetchPlan([list.files[1]], of: list)
        #expect(plan.listID == 7)
        #expect(plan.items == ["Folder"])
        #expect(plan.folders == ["Folder", "Folder/Sub"])
        #expect(
            plan.files == [.init(listIndex: 2, path: "Folder/a.txt"), .init(listIndex: 5, path: "Folder/Sub/b.txt")]
        )

        // Not in the list: left out.
        let stranger = RDPClipboardFile(path: "Elsewhere.txt", size: 1, isFolder: false)
        let both = RDPFetchPlan([list.files[0], stranger], of: list)
        #expect(both.items == ["Report.bin"])
        #expect(both.files == [.init(listIndex: 0, path: "Report.bin")])
    }

    @Test func theLatestClipboardWinsWhileInputWaits() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        let offer = RDPLocalFileOffer(urls: [try scratch.file("a.txt", "a")])
        #expect(RDPInputEvent.clipboardText("x").isSuperseded(by: .clipboardFiles(offer)))
        #expect(RDPInputEvent.clipboardFiles(offer).isSuperseded(by: .clipboardText("y")))
        #expect(RDPInputEvent.clipboardFiles(offer).isSuperseded(by: .clipboardFiles(offer)))
    }

    @Test func progressCountsBytesOrElseFiles() {
        #expect(RDPFileFetchProgress(bytesReceived: 5, bytesExpected: 10, filesDone: 0, fileCount: 2)
            .fractionCompleted == 0.5)
        #expect(RDPFileFetchProgress(bytesReceived: 0, bytesExpected: 0, filesDone: 1, fileCount: 2)
            .fractionCompleted == 0.5)
        #expect(RDPFileFetchProgress(bytesReceived: 0, bytesExpected: 0, filesDone: 0, fileCount: 0)
            .fractionCompleted == 1)
    }
}
