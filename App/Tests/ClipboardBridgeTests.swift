import AppKit
import RDPKit
import Testing
@testable import Vistara

@Suite(.serialized)
@MainActor
struct ClipboardBridgeTests {
    private final class Sent {
        var texts: [String] = []
    }

    private struct Fixture {
        let bridge: ClipboardBridge
        let pasteboard: NSPasteboard
        let sent: Sent
    }

    private func make(inFront: @escaping () -> Bool = { true }) -> Fixture {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.sysmike.vistara.tests.\(UUID().uuidString)"))
        let sent = Sent()
        let bridge = ClipboardBridge(pasteboard: pasteboard, send: { events in
            for case .clipboardText(let text) in events { sent.texts.append(text) }
        }, isInFront: inFront)
        return Fixture(bridge: bridge, pasteboard: pasteboard, sent: sent)
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard, extra: [NSPasteboard.PasteboardType] = []) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + extra, owner: nil)
        pasteboard.setString(text, forType: .string)
        for type in extra { pasteboard.setString("", forType: type) }
    }

    @Test
    func newTextIsOfferedOnce() {
        let fixture = make()
        let (bridge, pasteboard, sent) = (fixture.bridge, fixture.pasteboard, fixture.sent)
        copy("Grüße ✓", to: pasteboard)
        bridge.checkMacClipboard()
        bridge.checkMacClipboard()
        #expect(sent.texts == ["Grüße ✓"])
        copy("again", to: pasteboard)
        bridge.checkMacClipboard()
        #expect(sent.texts == ["Grüße ✓", "again"])
    }

    @Test
    func nothingLeavesTheMacWhileTheSessionIsNotInFront() {
        var inFront = false
        let fixture = make(inFront: { inFront })
        let (bridge, pasteboard, sent) = (fixture.bridge, fixture.pasteboard, fixture.sent)
        copy("secret", to: pasteboard)
        bridge.checkMacClipboard()
        #expect(sent.texts.isEmpty)
        // Going to the session offers what was copied meanwhile.
        inFront = true
        bridge.checkMacClipboard()
        #expect(sent.texts == ["secret"])
    }

    @Test
    func textFromTheRemoteComputerIsNotOfferedBack() {
        let fixture = make()
        let (bridge, pasteboard, sent) = (fixture.bridge, fixture.pasteboard, fixture.sent)
        bridge.receive("from Windows")
        #expect(pasteboard.string(forType: .string) == "from Windows")
        bridge.checkMacClipboard()
        #expect(sent.texts.isEmpty)
    }

    @Test
    func concealedAndTransientItemsStayOnTheMac() {
        let fixture = make()
        let (bridge, pasteboard, sent) = (fixture.bridge, fixture.pasteboard, fixture.sent)
        copy("p4ssword", to: pasteboard, extra: [ClipboardBridge.concealed])
        bridge.checkMacClipboard()
        copy("one-time code", to: pasteboard, extra: [ClipboardBridge.transient])
        bridge.checkMacClipboard()
        #expect(sent.texts.isEmpty)
        #expect(ClipboardBridge.mayShare([.string]))
    }
}
