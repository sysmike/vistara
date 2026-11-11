import Foundation
import Testing

@testable import RDPKit

/// A source framebuffer with padded rows, as FreeRDP may provide.
private struct Source {
    let width: Int
    let height: Int
    let stride: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, padding: Int = 8, fill: UInt8) {
        self.width = width
        self.height = height
        stride = width * 4 + padding
        bytes = [UInt8](repeating: 0xEE, count: stride * height)
        for row in 0..<height {
            for column in 0..<(width * 4) { bytes[row * stride + column] = fill }
        }
    }

    mutating func fill(_ rect: RDPFramebuffer.Rect, with value: UInt8) {
        for row in rect.y..<(rect.y + rect.height) {
            for column in (rect.x * 4)..<((rect.x + rect.width) * 4) { bytes[row * stride + column] = value }
        }
    }

    func write(to framebuffer: RDPFramebuffer, dirty: RDPFramebuffer.Rect) {
        bytes.withUnsafeBufferPointer {
            framebuffer.write(from: $0, stride: stride, width: width, height: height, dirty: dirty)
        }
    }
}

@Test func firstWriteCoversTheWholeDesktopWhateverWasDirty() {
    let framebuffer = RDPFramebuffer()
    #expect(framebuffer.takeUpdate() == nil)

    Source(width: 8, height: 4, fill: 1).write(to: framebuffer, dirty: .init(x: 2, y: 1, width: 1, height: 1))
    let update = framebuffer.takeUpdate()

    #expect(update?.desktopWidth == 8)
    #expect(update?.desktopHeight == 4)
    #expect(update?.rect == .init(x: 0, y: 0, width: 8, height: 4))
    // Row padding from the source is not carried over.
    #expect(update?.pixels == Data(repeating: 1, count: 8 * 4 * 4))
    #expect(framebuffer.size.width == 8)
    #expect(framebuffer.size.height == 4)
    #expect(framebuffer.takeUpdate() == nil)
}

@Test func laterWritesReportOnlyTheChangedArea() {
    let framebuffer = RDPFramebuffer()
    var source = Source(width: 8, height: 4, fill: 1)
    source.write(to: framebuffer, dirty: .init(x: 0, y: 0, width: 8, height: 4))
    _ = framebuffer.takeUpdate()

    let changed = RDPFramebuffer.Rect(x: 3, y: 1, width: 2, height: 2)
    source.fill(changed, with: 7)
    source.write(to: framebuffer, dirty: changed)
    let update = framebuffer.takeUpdate()

    #expect(update?.rect == changed)
    #expect(update?.pixels == Data(repeating: 7, count: 2 * 2 * 4))
}

@Test func changesBetweenTwoReadsAreCoalescedIntoOneUpdate() {
    let framebuffer = RDPFramebuffer()
    var source = Source(width: 8, height: 4, fill: 1)
    source.write(to: framebuffer, dirty: .init(x: 0, y: 0, width: 8, height: 4))
    _ = framebuffer.takeUpdate()

    let first = RDPFramebuffer.Rect(x: 0, y: 0, width: 1, height: 1)
    let second = RDPFramebuffer.Rect(x: 6, y: 3, width: 2, height: 1)
    source.fill(first, with: 5)
    source.write(to: framebuffer, dirty: first)
    source.fill(second, with: 9)
    source.write(to: framebuffer, dirty: second)
    let update = framebuffer.takeUpdate()

    #expect(update?.rect == .init(x: 0, y: 0, width: 8, height: 4))
    #expect(update?.pixels.first == 5)
    #expect(update?.pixels.last == 9)
    #expect(framebuffer.takeUpdate() == nil)
}

@Test func resizeReplacesEverything() {
    let framebuffer = RDPFramebuffer()
    Source(width: 8, height: 4, fill: 1).write(to: framebuffer, dirty: .init(x: 0, y: 0, width: 8, height: 4))
    _ = framebuffer.takeUpdate()

    Source(width: 4, height: 2, fill: 3).write(to: framebuffer, dirty: .init(x: 0, y: 0, width: 1, height: 1))
    let update = framebuffer.takeUpdate()

    #expect(update?.desktopWidth == 4)
    #expect(update?.desktopHeight == 2)
    #expect(update?.rect == .init(x: 0, y: 0, width: 4, height: 2))
    #expect(update?.pixels == Data(repeating: 3, count: 4 * 2 * 4))
}

@Test func dirtyAreaOutsideTheDesktopIsClippedOrIgnored() {
    let framebuffer = RDPFramebuffer()
    var source = Source(width: 8, height: 4, fill: 1)
    source.write(to: framebuffer, dirty: .init(x: 0, y: 0, width: 8, height: 4))
    _ = framebuffer.takeUpdate()

    source.write(to: framebuffer, dirty: .init(x: 20, y: 20, width: 5, height: 5))
    #expect(framebuffer.takeUpdate() == nil)

    source.fill(.init(x: 6, y: 2, width: 2, height: 2), with: 4)
    source.write(to: framebuffer, dirty: .init(x: 6, y: 2, width: 50, height: 50))
    #expect(framebuffer.takeUpdate()?.rect == .init(x: 6, y: 2, width: 2, height: 2))
}

@Test func aSourceThatIsTooSmallIsIgnored() {
    let framebuffer = RDPFramebuffer()
    [UInt8](repeating: 0, count: 16).withUnsafeBufferPointer {
        framebuffer.write(from: $0, stride: 32, width: 8, height: 4, dirty: .init(x: 0, y: 0, width: 8, height: 4))
    }
    #expect(framebuffer.takeUpdate() == nil)
}

@Test(.timeLimit(.minutes(1))) func changesStreamSignalsOncePerBurstAndEndsWithTheSession() async {
    let framebuffer = RDPFramebuffer()
    let source = Source(width: 8, height: 4, fill: 1)
    for _ in 0..<5 { source.write(to: framebuffer, dirty: .init(x: 0, y: 0, width: 8, height: 4)) }
    framebuffer.finish()

    var signals = 0
    for await _ in framebuffer.changes { signals += 1 }
    #expect(signals == 1)
}
