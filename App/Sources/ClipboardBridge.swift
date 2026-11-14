import AppKit
import RDPKit

/// Shares the Mac's clipboard with one session's remote computer: text, and
/// files when the connection copies them (docs/DESIGN.md, Clipboard and
/// Copying files).
///
/// - What the remote computer copies is put on the Mac's clipboard at once.
///   Its files are fetched only when pasted (RemoteFilePaste).
/// - What is copied on the Mac is offered to the remote computer only while
///   its session window is in front, so it does not leave the Mac until you
///   go to that session. Copied files are offered in place of text.
/// - Items that password managers mark as concealed or transient are never
///   offered (the `org.nspasteboard` convention).
///
/// Clipboard text and file names are never logged.
@MainActor
final class ClipboardBridge {
    static let checkInterval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let send: ([RDPInputEvent]) -> Void
    private let isInFront: () -> Bool
    /// The remote computer's files, when the connection copies files.
    let files: RemoteFilePaste?
    /// The change count already dealt with: offered, skipped, or written by us.
    private(set) var handledChangeCount: Int?
    /// The change count of what this bridge wrote last.
    private var writtenChangeCount: Int?
    /// The remote computer's text, written along with its files.
    private var remoteText: String?
    private var timer: Timer?
    private var listeners: [Task<Void, Never>] = []
    private var offering: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general,
        send: @escaping ([RDPInputEvent]) -> Void,
        isInFront: @escaping () -> Bool,
        files: RemoteFilePaste? = nil
    ) {
        self.pasteboard = pasteboard
        self.send = send
        self.isInFront = isInFront
        self.files = files
    }

    /// Starts sharing: listens to the remote computer and watches the Mac.
    func start(remote: AsyncStream<String>, remoteFiles: AsyncStream<RDPRemoteFiles>? = nil) {
        stop()
        listeners.append(Task { [weak self] in
            for await text in remote { self?.receive(text) }
        })
        if let remoteFiles, files != nil {
            listeners.append(Task { [weak self] in
                for await list in remoteFiles { self?.receive(list) }
            })
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMacClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkMacClipboard()
    }

    /// Stops sharing. The remote computer's files leave the clipboard and
    /// the fetched ones are removed.
    func stop() {
        timer?.invalidate()
        timer = nil
        listeners.forEach { $0.cancel() }
        listeners = []
        offering?.cancel()
        offering = nil
        guard let files, files.hasFiles else { return }
        if pasteboard.changeCount == writtenChangeCount {
            pasteboard.clearContents()
        }
        files.replace(with: nil)
    }

    /// Text from the remote computer goes on the Mac's clipboard, with the
    /// files it copied along with it.
    func receive(_ text: String) {
        remoteText = text
        writeRemote()
    }

    /// The remote computer copied files, or something else (an empty list):
    /// they replace what it copied before.
    func receive(_ list: RDPRemoteFiles) {
        guard let files else { return }
        let hadFiles = files.hasFiles
        files.replace(with: list)
        remoteText = nil
        if files.hasFiles {
            writeRemote()
        } else if hadFiles, pasteboard.changeCount == writtenChangeCount {
            pasteboard.clearContents()
            handledChangeCount = pasteboard.changeCount
        }
    }

    private func writeRemote() {
        var items = files?.pasteboardItems() ?? []
        if let remoteText {
            if items.isEmpty { items = [NSPasteboardItem()] }
            items[0].setString(remoteText, forType: .string)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        // Not to be offered straight back.
        handledChangeCount = pasteboard.changeCount
        writtenChangeCount = handledChangeCount
    }

    /// Offers what is on the Mac's clipboard, if it is new, may be shared, and
    /// the session is in front: files when the connection copies them and
    /// files were copied, otherwise text.
    func checkMacClipboard() {
        let count = pasteboard.changeCount
        // Something else was copied: the remote computer's files are gone.
        if let files, files.hasFiles, count != writtenChangeCount {
            files.replace(with: nil)
        }
        guard isInFront(), count != handledChangeCount else { return }
        handledChangeCount = count
        let types = pasteboard.types ?? []
        guard Self.mayShare(types) else { return }
        // Another session's remote files would be fetched just to be offered
        // here, though nobody pasted them: they are left on the Mac.
        if files != nil, !types.contains(RemoteFilePaste.itemType), let urls = fileURLs(), !urls.isEmpty {
            offer(urls, copiedAt: count)
            return
        }
        guard let text = pasteboard.string(forType: .string) else { return }
        send([.clipboardText(text)])
    }

    private func fileURLs() -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    /// Lists the files off the main thread, then offers them unless something
    /// else was copied meanwhile.
    private func offer(_ urls: [URL], copiedAt count: Int) {
        offering?.cancel()
        offering = Task { [weak self] in
            let offer = await Task.detached { RDPLocalFileOffer(urls: urls) }.value
            guard let self, !Task.isCancelled, pasteboard.changeCount == count else { return }
            send([.clipboardFiles(offer)])
        }
    }

    /// Waits until the files copied last are listed and offered. For tests.
    func waitUntilOffered() async {
        await offering?.value
    }

    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func mayShare(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.contains(concealed) && !types.contains(transient)
    }
}
