import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Vistara

/// The file clipboard spike (#134): what the sandboxed app can do with files
/// on the general pasteboard. A helper outside the sandbox stands in for the
/// Finder (scripts/test-pasteboard/pasteboard-helper.swift); the CI step runs
/// it when a test asks through a file in this container.
@Suite(.serialized, .enabled(if: PasteboardHelper.isAvailable, "Needs the CI pasteboard helper"))
@MainActor
struct FileClipboardProbeTests {
    /// Mac to remote computer: files copied by another app, read without
    /// anyone choosing them again.
    /// Other tests' sessions may put text on the pasteboard meanwhile (the test
    /// server offers some when a session starts), so a probe whose pasteboard
    /// changed under it is tried again.
    private static let attempts = 3

    @Test(.timeLimit(.minutes(2)))
    func filesCopiedByAnotherAppCanBeRead() async throws {
        var copied: [String: Any] = [:]
        var urls: [URL] = []
        var beforePasteboard = false
        var control = false
        for _ in 0..<Self.attempts {
            copied = try await PasteboardHelper.run("copy")
            if let path = copied["control"] as? String {
                control = (try? Data(contentsOf: URL(fileURLWithPath: path))) != nil
            }
            // Outside the container: the sandbox keeps the app out on its own.
            if let path = copied["file"] as? String {
                beforePasteboard = (try? Data(contentsOf: URL(fileURLWithPath: path))) != nil
            }
            urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            if urls.count == 2 { break }
        }
        let file = URL(fileURLWithPath: try #require(copied["file"] as? String))
        let folder = URL(fileURLWithPath: try #require(copied["folder"] as? String), isDirectory: true)
        #expect(copied["written"] as? Bool == true)
        #expect(urls.map(\.lastPathComponent) == ["Report.txt", "Folder"])
        let read = try? String(contentsOf: file, encoding: .utf8)
        let inner = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        let innerText = try? String(contentsOf: folder.appendingPathComponent("Inner.txt"), encoding: .utf8)
        PasteboardHelper.report(
            "copy", ["readControl": control, "readBeforePasteboard": beforePasteboard, "readFile": read != nil,
                     "listFolder": inner ?? [], "readInsideFolder": innerText != nil]
        )
        #expect(read == "Quarterly report\n")
        #expect(inner == ["Inner.txt"])
        #expect(innerText == "Inside the folder\n")
    }

    /// Remote computer to Mac: a file promise on the general pasteboard,
    /// written on a queue of its own while another app pastes it. The main
    /// thread stays free meanwhile.
    @Test(.timeLimit(.minutes(2)))
    func aPromisedFileIsPastedWithoutBlockingTheMainThread() async throws {
        let writer = SlowPromiseWriter(size: 4 * 1024 * 1024, chunks: 20, pause: .milliseconds(50))
        var pasted: [String: Any] = [:]
        var files: [[String: Any]] = []
        var elapsed = Duration.zero
        var longestGap = Duration.zero
        for _ in 0..<Self.attempts {
            let provider = NSFilePromiseProvider(fileType: UTType.data.identifier, delegate: writer)
            NSPasteboard.general.clearContents()
            #expect(NSPasteboard.general.writeObjects([provider]))

            let started = ContinuousClock.now
            var last = ContinuousClock.now
            longestGap = .zero
            pasted = try await PasteboardHelper.run("receive") {
                let now = ContinuousClock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
            elapsed = ContinuousClock.now - started
            withExtendedLifetime(provider) {}
            files = pasted["files"] as? [[String: Any]] ?? []
            if !files.isEmpty { break }
        }

        PasteboardHelper.report(
            "receive", ["files": files, "elapsedMs": elapsed.milliseconds, "longestMainGapMs": longestGap.milliseconds,
                        "error": pasted["error"] ?? "", "timedOut": pasted["timedOut"] ?? "",
                        "types": pasted["types"] ?? [], "promisedTypes": pasted["promisedTypes"] ?? [],
                        "askedForName": writer.askedForName]
        )
        #expect(files.count == 1)
        #expect(files.first?["name"] as? String == "Promised.bin")
        #expect(files.first?["size"] as? Int == 4 * 1024 * 1024)
        #expect(writer.wroteOnMainThread == false)
        #expect(longestGap < .milliseconds(500))
    }

    /// Remote computer to Mac, another way: a file URL provided only when
    /// pasted, by a data provider on a thread of its own, which fetches the
    /// file into the container first. Whether the main thread stays free.
    @Test(.timeLimit(.minutes(2)))
    func aFileURLProvidedOnABackgroundThreadIsPastedWithoutBlockingTheMainThread() async throws {
        var pasted: [String: Any] = [:]
        var files: [[String: Any]] = []
        var longestGap = Duration.zero
        var offer: BackgroundFileOffer?
        for _ in 0..<Self.attempts {
            let current = BackgroundFileOffer(size: 1024 * 1024, delay: 1.5)
            offer = current
            current.start()
            var last = ContinuousClock.now
            longestGap = .zero
            pasted = try await PasteboardHelper.run("read-urls") {
                let now = ContinuousClock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
            current.stop()
            files = pasted["files"] as? [[String: Any]] ?? []
            if !files.isEmpty { break }
        }
        PasteboardHelper.report(
            "read-urls", ["files": files, "longestMainGapMs": longestGap.milliseconds,
                          "providedOnMainThread": offer?.providedOnMainThread ?? "never",
                          "types": pasted["types"] ?? [], "seconds": pasted["seconds"] ?? ""]
        )
        #expect(files.first?["name"] as? String == "Fetched.bin")
        #expect(files.first?["size"] as? Int == 1024 * 1024)
        #expect(offer?.providedOnMainThread == false)
        #expect(longestGap < .milliseconds(500))
    }

    /// The same file promise between two apps outside the sandbox, to tell
    /// whether the sandbox or the pasteboard keeps a promise from being kept.
    @Test(.timeLimit(.minutes(2)))
    func aFilePromiseBetweenTwoAppsOutsideTheSandbox() async throws {
        let pasted = try await PasteboardHelper.run("promise-roundtrip")
        PasteboardHelper.report("promise-roundtrip", pasted)
    }

    /// Remote computer to Mac, a third way: the provider is asked on the main
    /// thread, and keeps its run loop turning while a background thread fetches
    /// the file, as a progress panel would. Whether the main thread stays free.
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
        #expect(longestGap < .milliseconds(500))
    }
}

/// Writes a promised file in pieces, with pauses, as a download from the
/// remote computer would arrive.
private final class SlowPromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let size: Int
    let chunks: Int
    let pause: Duration
    private(set) var wroteOnMainThread: Bool?
    private(set) var askedForName = false
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Promised file writer"
        return queue
    }()

    init(size: Int, chunks: Int, pause: Duration) {
        self.size = size
        self.chunks = chunks
        self.pause = pause
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        askedForName = true
        return "Promised.bin"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        wroteOnMainThread = Thread.isMainThread
        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let piece = Data(repeating: 0x5A, count: size / chunks)
            for _ in 0..<chunks {
                try handle.write(contentsOf: piece)
                Thread.sleep(forTimeInterval: Double(pause.components.attoseconds) / 1e18)
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
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

/// Puts one file URL on the general pasteboard from a thread with a run loop
/// of its own, provided only when another app asks: the provider waits as a
/// download would, writes the file into the container, and answers its URL.
private final class BackgroundFileOffer: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let size: Int
    let delay: TimeInterval
    private(set) var providedOnMainThread: Bool?
    private var isStopped = false
    private let written = DispatchSemaphore(value: 0)

    init(size: Int, delay: TimeInterval) {
        self.size = size
        self.delay = delay
    }

    func start() {
        let thread = Thread { [self] in
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: [.fileURL])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            written.signal()
            while !isStopped {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
        }
        thread.name = "Pasteboard offer"
        thread.start()
        written.wait()
    }

    func stop() {
        isStopped = true
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        providedOnMainThread = Thread.isMainThread
        Thread.sleep(forTimeInterval: delay)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fetched.bin")
        try? Data(repeating: 0xA5, count: size).write(to: url)
        item.setString(url.absoluteString, forType: .fileURL)
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
