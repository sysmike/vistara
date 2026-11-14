import AppKit
import Foundation
import Testing
@testable import Vistara

/// The file clipboard spike (#134): what the app can do with files on the
/// general pasteboard. A helper outside the sandbox stands in for the Finder
/// (scripts/test-pasteboard/pasteboard-helper.swift); the CI step runs it
/// when a test asks through a file in this container. The decision, and the
/// ways that did not work, are on issue #134.
@Suite(.serialized, .enabled(if: PasteboardHelper.isAvailable, "Needs the CI pasteboard helper"))
@MainActor
struct FileClipboardProbeTests {
    /// Other tests' sessions may put text on the pasteboard meanwhile (the test
    /// server offers some when a session starts), so a probe whose pasteboard
    /// changed under it is tried again.
    private static let attempts = 3

    /// Mac to remote computer: files and a folder copied by another app, read
    /// from their file URLs. (In CI the test host may read the home folder
    /// anyway, so whether the sandbox lets a signed build read them is checked
    /// on a real Mac: #6.)
    @Test(.timeLimit(.minutes(2)))
    func filesCopiedByAnotherAppCanBeRead() async throws {
        var copied: [String: Any] = [:]
        var urls: [URL] = []
        for _ in 0..<Self.attempts {
            copied = try await PasteboardHelper.run("copy")
            urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            if urls.count == 2 { break }
        }
        let file = URL(fileURLWithPath: try #require(copied["file"] as? String))
        let folder = URL(fileURLWithPath: try #require(copied["folder"] as? String), isDirectory: true)
        #expect(urls.map(\.lastPathComponent) == ["Report.txt", "Folder"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "Quarterly report\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Inner.txt"])
        #expect(try String(contentsOf: folder.appendingPathComponent("Inner.txt"), encoding: .utf8)
            == "Inside the folder\n")
    }

    /// Remote computer to Mac: a file URL provided only when another app
    /// pastes it. The pasteboard asks on the main thread, so the provider
    /// starts the fetch on a background thread and keeps the main run loop
    /// turning until it is done: the main thread stays free.
    @Test(.timeLimit(.minutes(2)))
    func aFileURLFetchedWhileTheMainRunLoopTurns() async throws {
        var pasted: [String: Any] = [:]
        var files: [[String: Any]] = []
        var longestGap = Duration.zero
        var offer: SpinningFileOffer?
        for _ in 0..<Self.attempts {
            let current = SpinningFileOffer(size: 1024 * 1024, delay: 1.5)
            offer = current
            current.start()
            var last = ContinuousClock.now
            longestGap = .zero
            pasted = try await PasteboardHelper.run("read-urls") {
                let now = ContinuousClock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
            files = pasted["files"] as? [[String: Any]] ?? []
            if !files.isEmpty { break }
        }
        PasteboardHelper.report(
            "spinning", ["files": files, "longestMainGapMs": longestGap.milliseconds,
                         "providedOnMainThread": offer?.providedOnMainThread ?? "never",
                         "seconds": pasted["seconds"] ?? ""]
        )
        #expect(files.first?["name"] as? String == "Fetched.bin")
        #expect(files.first?["size"] as? Int == 1024 * 1024)
        #expect(offer?.providedOnMainThread == true)
        #expect(longestGap < .milliseconds(500))
    }
}

/// Puts one file URL on the general pasteboard, provided only when another
/// app asks. The provider, asked on the main thread, starts the fetch on a
/// background thread and keeps the main run loop turning until it is done.
private final class SpinningFileOffer: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let size: Int
    let delay: TimeInterval
    private(set) var providedOnMainThread: Bool?

    init(size: Int, delay: TimeInterval) {
        self.size = size
        self.delay = delay
    }

    @MainActor
    func start() {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.fileURL])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        providedOnMainThread = Thread.isMainThread
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fetched.bin")
        let done = DispatchSemaphore(value: 0)
        let size = size
        let delay = delay
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: delay)
            try? Data(repeating: 0x3C, count: size).write(to: url)
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        item.setString(url.absoluteString, forType: .fileURL)
    }
}

/// Asks the CI pasteboard helper to act, through files in this container.
enum PasteboardHelper {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vistara-pasteboard")

    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["VISTARA_PASTEBOARD_HELPER"] == "1"
    }

    /// Writes `<name>.request` holding the command and waits for
    /// `<name>.json`, calling `tick` on the main actor while it waits.
    @MainActor
    static func run(_ command: String, tick: () -> Void = {}) async throws -> [String: Any] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(command)-\(UUID().uuidString)"
        let answer = directory.appendingPathComponent("\(name).json")
        try Data(command.utf8).write(to: directory.appendingPathComponent("\(name).request"))
        let deadline = ContinuousClock.now + .seconds(40)
        while ContinuousClock.now < deadline {
            tick()
            if let data = try? Data(contentsOf: answer), !data.isEmpty {
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    /// What a probe found, for the spike's written decision. Goes to the test log.
    static func report(_ probe: String, _ findings: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: findings, options: [.sortedKeys])) ?? Data()
        print("vistara-probe \(probe) \(String(bytes: data, encoding: .utf8) ?? "")")
    }
}

private extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
