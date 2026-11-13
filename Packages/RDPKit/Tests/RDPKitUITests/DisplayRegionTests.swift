import Metal
import Testing

@testable import RDPKit
@testable import RDPKitUI

/// A view that shows one display's region of a desktop across several
/// (docs/DESIGN.md, Multiple displays; #112).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Needs a Metal device"))
@MainActor
struct DisplayRegionRenderingTests {
    private let blue: [UInt8] = [0xFF, 0x00, 0x00, 0x00]
    private let green: [UInt8] = [0x00, 0xFF, 0x00, 0x00]

    /// Left half blue, right half green, 16 x 8.
    private func halves(_ renderer: FrameRenderer) {
        let row = Array(repeating: blue, count: 8).flatMap { $0 } + Array(repeating: green, count: 8).flatMap { $0 }
        let pixels = Data(Array(repeating: row, count: 8).flatMap { $0 })
        _ = renderer.apply(RDPFrameUpdate(
            desktopWidth: 16, desktopHeight: 8, rect: .init(x: 0, y: 0, width: 16, height: 8), pixels: pixels
        ))
    }

    /// The colour drawn in the middle of an 8 x 8 target, without alpha.
    private func middle(_ renderer: FrameRenderer, region: CGRect?) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: FrameRenderer.pixelFormat, width: 8, height: 8, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let buffer = try #require(renderer.draw(pass: pass, targetSize: CGSize(width: 8, height: 8), region: region))
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 4)
        target.getBytes(&bytes, bytesPerRow: 8 * 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        return Array(bytes.prefix(3))
    }

    @Test func eachRegionShowsItsPart() throws {
        let renderer = try FrameRenderer(device: try #require(MTLCreateSystemDefaultDevice()))
        halves(renderer)
        #expect(try middle(renderer, region: CGRect(x: 0, y: 0, width: 8, height: 8)) == [0xFF, 0, 0])
        #expect(try middle(renderer, region: CGRect(x: 8, y: 0, width: 8, height: 8)) == [0, 0xFF, 0])
        // A region beyond the desktop draws nothing.
        #expect(try middle(renderer, region: CGRect(x: 40, y: 0, width: 8, height: 8)) == [0, 0, 0])
    }
}

@Suite
struct DisplayRegionPointerTests {
    /// The pointer in a display's view lands in that display's part of the
    /// desktop.
    @Test func thePointerIsOffsetByTheRegion() {
        let size = CGSize(width: 800, height: 600)
        let geometry = PointerTranslator.Geometry(viewSize: size, desktopSize: size, origin: CGPoint(x: 1024, y: 56))
        var pointer = PointerTranslator()
        // 10 points from the left and from the top.
        #expect(pointer.moved(to: CGPoint(x: 10.5, y: 589.5), in: geometry) == [.pointerMove(x: 1034, y: 66)])
    }
}
