import AppKit
import RDPKit

/// Shares text between the Mac's clipboard and one session's remote computer.
///
/// - What the remote computer copies is put on the Mac's clipboard at once.
/// - What is copied on the Mac is offered to the remote computer only while
///   its session window is in front, so it does not leave the Mac until you
///   go to that session.
/// - Items that password managers mark as concealed or transient are never
///   offered (the `org.nspasteboard` convention).
///
/// Clipboard text is never logged.
@MainActor
final class ClipboardBridge {
    static let checkInterval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let send: ([RDPInputEvent]) -> Void
    private let isInFront: () -> Bool
    /// The change count already dealt with: offered, skipped, or written by us.
    private(set) var handledChangeCount: Int?
    private var timer: Timer?
    private var listener: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general,
        send: @escaping ([RDPInputEvent]) -> Void,
        isInFront: @escaping () -> Bool
    ) {
        self.pasteboard = pasteboard
        self.send = send
        self.isInFront = isInFront
    }

    /// Starts sharing: listens to the remote computer and watches the Mac.
    func start(remote: AsyncStream<String>) {
        stop()
        listener = Task { [weak self] in
            for await text in remote {
                self?.receive(text)
            }
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMacClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkMacClipboard()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        listener?.cancel()
        listener = nil
    }

    /// Text from the remote computer goes on the Mac's clipboard.
    func receive(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Not to be offered straight back.
        handledChangeCount = pasteboard.changeCount
    }

    /// Offers what is on the Mac's clipboard, if it is new, is text, may be
    /// shared, and the session is in front.
    func checkMacClipboard() {
        guard isInFront() else { return }
        let count = pasteboard.changeCount
        guard count != handledChangeCount else { return }
        handledChangeCount = count
        guard Self.mayShare(pasteboard.types ?? []), let text = pasteboard.string(forType: .string) else { return }
        send([.clipboardText(text)])
    }

    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func mayShare(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.contains(concealed) && !types.contains(transient)
    }
}
