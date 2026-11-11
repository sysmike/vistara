import CoreGraphics
import Metal
import RDPKit

/// Keeps the remote desktop in a texture and draws it, scaled to fit.
///
/// Only the changed part of the desktop is uploaded for each update.
@MainActor
final class FrameRenderer {
    enum SetupError: Error {
        case pipelineUnavailable
    }

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut vistara_vertex(uint vertexID [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
            float2 corner = corners[vertexID];
            VertexOut out;
            out.position = float4(corner * scale, 0, 1);
            out.uv = float2((corner.x + 1) * 0.5, (1 - corner.y) * 0.5);
            return out;
        }

        fragment float4 vistara_fragment(VertexOut in [[stage_in]],
                                         texture2d<float> desktop [[texture(0)]],
                                         sampler desktopSampler [[sampler(0)]]) {
            // The remote alpha channel carries no meaning; the desktop is opaque.
            return float4(desktop.sample(desktopSampler, in.uv).rgb, 1);
        }
        """

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private var texture: (any MTLTexture)?

    /// Size of the remote desktop in pixels, zero before the first update.
    private(set) var desktopSize = CGSize.zero

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SetupError.pipelineUnavailable }
        self.queue = queue

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vistara_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "vistara_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw SetupError.pipelineUnavailable
        }
        self.sampler = sampler
    }

    /// Uploads the changed pixels. Returns false when the update cannot be
    /// applied: it does not fit the texture, or the texture cannot be made.
    @discardableResult
    func apply(_ update: RDPFrameUpdate) -> Bool {
        let size = CGSize(width: update.desktopWidth, height: update.desktopHeight)
        let rect = update.rect
        let rowBytes = rect.width * 4
        guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
            rect.x + rect.width <= update.desktopWidth, rect.y + rect.height <= update.desktopHeight,
            update.pixels.count == rowBytes * rect.height
        else { return false }

        if texture == nil || size != desktopSize {
            // A new texture starts empty, so the update must cover all of it.
            guard rect.x == 0, rect.y == 0, rect.width == update.desktopWidth, rect.height == update.desktopHeight
            else { return false }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat,
                width: update.desktopWidth,
                height: update.desktopHeight,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
            self.texture = texture
            desktopSize = size
        }

        update.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture?.replace(
                region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: rowBytes
            )
        }
        return true
    }

    /// Draws the desktop, scaled to fit `targetSize`, into `pass`. The area
    /// around it keeps the pass's clear colour. Returns the command buffer,
    /// not yet committed, so the caller can present a drawable or wait for it.
    func draw(pass: MTLRenderPassDescriptor, targetSize: CGSize) -> (any MTLCommandBuffer)? {
        guard let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }

        if let texture {
            var scale = FitLayout.scale(content: desktopSize, container: targetSize)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return commandBuffer
    }
}
