import AppKit
import Metal
import Testing

@testable import RDPKit
@testable import RDPKitUI

// MARK: Layout

@Test func desktopIsScaledToFitWithoutStretching() {
    // A 4:3 desktop in a wide view fills the height.
    let wide = FitLayout.scale(content: CGSize(width: 800, height: 600), container: CGSize(width: 1600, height: 600))
    #expect(wide == SIMD2<Float>(0.5, 1))
    // In a tall view it fills the width.
    let tall = FitLayout.scale(content: CGSize(width: 800, height: 600), container: CGSize(width: 800, height: 1200))
    #expect(tall == SIMD2<Float>(1, 0.5))
    // Same shape: fills both.
    let same = FitLayout.scale(content: CGSize(width: 800, height: 600), container: CGSize(width: 400, height: 300))
    #expect(same == SIMD2<Float>(1, 1))
}

@Test func desktopFrameIsCentred() {
    let frame = FitLayout.frame(content: CGSize(width: 800, height: 600), container: CGSize(width: 1600, height: 600))
    #expect(frame == CGRect(x: 400, y: 0, width: 800, height: 600))
}

@Test func emptySizesGiveNoLayout() {
    #expect(FitLayout.scale(content: .zero, container: CGSize(width: 10, height: 10)) == SIMD2<Float>(0, 0))
    #expect(FitLayout.frame(content: CGSize(width: 10, height: 10), container: .zero) == .zero)
}

// MARK: Rendering

private func solid(_ color: [UInt8], width: Int, height: Int) -> Data {
    Data((0..<(width * height)).flatMap { _ in color })
}

private func fullUpdate(_ color: [UInt8], width: Int, height: Int) -> RDPFrameUpdate {
    RDPFrameUpdate(
        desktopWidth: width,
        desktopHeight: height,
        rect: .init(x: 0, y: 0, width: width, height: height),
        pixels: solid(color, width: width, height: height)
    )
}

/// Draws into an offscreen texture and returns its BGRA bytes.
@MainActor
private func render(_ renderer: FrameRenderer, width: Int, height: Int) throws -> [UInt8] {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: FrameRenderer.pixelFormat,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try #require(renderer.device.makeTexture(descriptor: descriptor))

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store

    let commandBuffer = try #require(renderer.draw(pass: pass, targetSize: CGSize(width: width, height: height)))
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(
        &bytes,
        bytesPerRow: width * 4,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0
    )
    return bytes
}

private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
    Array(bytes[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
}

private let blue: [UInt8] = [0xFF, 0x00, 0x00, 0x00]
private let green: [UInt8] = [0x00, 0xFF, 0x00, 0x00]
private let opaqueBlue: [UInt8] = [0xFF, 0x00, 0x00, 0xFF]
private let opaqueGreen: [UInt8] = [0x00, 0xFF, 0x00, 0xFF]
private let opaqueBlack: [UInt8] = [0x00, 0x00, 0x00, 0xFF]

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Needs a Metal device"))
@MainActor
struct FrameRendererTests {
    let renderer: FrameRenderer

    init() throws {
        renderer = try FrameRenderer(device: try #require(MTLCreateSystemDefaultDevice()))
    }

    @Test func drawsTheDesktopOpaqueAtItsOwnSize() throws {
        #expect(renderer.apply(fullUpdate(blue, width: 16, height: 8)))
        let bytes = try render(renderer, width: 16, height: 8)

        // The remote alpha of zero must not make the desktop transparent.
        #expect(pixel(bytes, x: 0, y: 0, width: 16) == opaqueBlue)
        #expect(pixel(bytes, x: 15, y: 7, width: 16) == opaqueBlue)
    }

    @Test func uploadsOnlyTheChangedAreaAndKeepsTheRest() throws {
        #expect(renderer.apply(fullUpdate(blue, width: 16, height: 8)))
        let changed = RDPFrameUpdate(
            desktopWidth: 16,
            desktopHeight: 8,
            rect: .init(x: 4, y: 2, width: 4, height: 2),
            pixels: solid(green, width: 4, height: 2)
        )
        #expect(renderer.apply(changed))
        let bytes = try render(renderer, width: 16, height: 8)

        #expect(pixel(bytes, x: 4, y: 2, width: 16) == opaqueGreen)
        #expect(pixel(bytes, x: 7, y: 3, width: 16) == opaqueGreen)
        #expect(pixel(bytes, x: 3, y: 2, width: 16) == opaqueBlue)
        #expect(pixel(bytes, x: 8, y: 3, width: 16) == opaqueBlue)
        #expect(pixel(bytes, x: 4, y: 4, width: 16) == opaqueBlue)
    }

    @Test func rowsAreNotFlipped() throws {
        var pixels = solid(blue, width: 4, height: 4)
        pixels.replaceSubrange(0..<16, with: solid(green, width: 4, height: 1))
        let update = RDPFrameUpdate(
            desktopWidth: 4, desktopHeight: 4, rect: .init(x: 0, y: 0, width: 4, height: 4), pixels: pixels
        )
        #expect(renderer.apply(update))
        let bytes = try render(renderer, width: 4, height: 4)

        #expect(pixel(bytes, x: 1, y: 0, width: 4) == opaqueGreen)
        #expect(pixel(bytes, x: 1, y: 3, width: 4) == opaqueBlue)
    }

    @Test func letterboxesADesktopOfAnotherShape() throws {
        #expect(renderer.apply(fullUpdate(blue, width: 8, height: 8)))
        // A square desktop in a 32x8 target occupies the middle 8 columns.
        let bytes = try render(renderer, width: 32, height: 8)

        #expect(pixel(bytes, x: 2, y: 4, width: 32) == opaqueBlack)
        #expect(pixel(bytes, x: 29, y: 4, width: 32) == opaqueBlack)
        #expect(pixel(bytes, x: 16, y: 4, width: 32) == opaqueBlue)
        #expect(renderer.desktopSize == CGSize(width: 8, height: 8))
    }

    @Test func resizedDesktopReplacesTheTexture() throws {
        #expect(renderer.apply(fullUpdate(blue, width: 16, height: 8)))
        #expect(renderer.apply(fullUpdate(green, width: 8, height: 4)))
        let bytes = try render(renderer, width: 8, height: 4)

        #expect(renderer.desktopSize == CGSize(width: 8, height: 4))
        #expect(pixel(bytes, x: 7, y: 3, width: 8) == opaqueGreen)
    }

    @Test func rejectsUpdatesThatDoNotFit() {
        // A partial update cannot start a texture.
        let partial = RDPFrameUpdate(
            desktopWidth: 16, desktopHeight: 8, rect: .init(x: 1, y: 1, width: 2, height: 2),
            pixels: solid(blue, width: 2, height: 2)
        )
        #expect(!renderer.apply(partial))

        #expect(renderer.apply(fullUpdate(blue, width: 16, height: 8)))
        let outside = RDPFrameUpdate(
            desktopWidth: 16, desktopHeight: 8, rect: .init(x: 15, y: 7, width: 2, height: 2),
            pixels: solid(blue, width: 2, height: 2)
        )
        #expect(!renderer.apply(outside))
        let wrongLength = RDPFrameUpdate(
            desktopWidth: 16, desktopHeight: 8, rect: .init(x: 0, y: 0, width: 2, height: 2), pixels: Data(count: 3)
        )
        #expect(!renderer.apply(wrongLength))
    }

    @Test func drawsOnlyTheClearColourBeforeTheFirstUpdate() throws {
        let bytes = try render(renderer, width: 4, height: 4)
        #expect(pixel(bytes, x: 2, y: 2, width: 4) == opaqueBlack)
    }
}

// MARK: View

@MainActor
@Test func viewDescribesItselfToAssistiveTechnology() {
    let view = RDPSessionView(framebuffer: RDPFramebuffer(), connectionName: "Build Server")

    #expect(view.isAccessibilityElement())
    #expect(view.accessibilityRole() == .image)
    #expect(view.accessibilityLabel() == "Remote desktop, Build Server")

    view.connectionName = "Jump Host"
    #expect(view.accessibilityLabel() == "Remote desktop, Jump Host")
}

@MainActor
@Test func viewDrawsOnDemandOnly() {
    let view = RDPSessionView(framebuffer: RDPFramebuffer(), connectionName: "Build Server")

    #expect(view.isPaused)
    #expect(view.enableSetNeedsDisplay)
    #expect(view.drawCount == 0)
}
