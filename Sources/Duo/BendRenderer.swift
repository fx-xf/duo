import Metal
import MetalKit
import CoreVideo

struct BendParams {
    /// How far the lid has folded toward the viewer past its clear angle, radians.
    var tilt: Double = 0
    var perspective: Double = 1
    var blur: Double = 0.65
    var shadow: Double = 0.35
}

private struct Uniforms {
    var size = SIMD2<Float>(1, 1)
    var eye: Float = 1
    var tilt: Float = 0
    var blurSpread: Float = 0
    var darkening: Float = 0
    var corner: Float = 0
    var maxLod: Float = 0
}

final class BendRenderer: NSObject, MTKViewDelegate {
    /// Eye to screen at full perspective: a laptop at arm's length.
    private static let eyeDistanceMillimetres = 500.0
    /// Slider maxima. At the default sliders these land on the reference
    /// frosted glass: 0.12 blur per unit of gap, ~1% of light lost per mm of gap.
    private static let blurSpreadRange = 0.18
    private static let darkeningPerMillimetreRange = 0.26

    let device: MTLDevice
    var params = BendParams()
    /// Top-corner radius of the panel, in texture pixels.
    var cornerRadius: Double = 0
    /// Physical density of the captured desktop, for the millimetre-based constants.
    var pixelsPerMillimetre: Double = 10

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var mipTexture: MTLTexture?

    private let frameLock = NSLock()
    private var pendingFrame: CVPixelBuffer?

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            NSLog("Duo: shader compile failed — \(error)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Called from the capture queue.
    func submit(frame: CVPixelBuffer) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    var hasFrame: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return pendingFrame != nil || mipTexture != nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encode(into: descriptor, commandBuffer: commandBuffer)
        commandBuffer.commit()
        // The layer presents with the Core Animation transaction, so this frame
        // lands together with the window being ordered in or out — no stale flash.
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }

    func encode(into descriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) {
        updateTexture(with: commandBuffer)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        defer { encoder.endEncoding() }

        // At zero tilt nothing is drawn and the pass clears to transparent, which
        // looks exactly like the overlay not being there at all.
        guard let texture = mipTexture, params.tilt > 0 else { return }

        var uniforms = makeUniforms(texture: texture)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func makeUniforms(texture: MTLTexture) -> Uniforms {
        let perMillimetre = max(pixelsPerMillimetre, 1)
        var uniforms = Uniforms()
        uniforms.size = SIMD2(Float(texture.width), Float(texture.height))
        // Weaker perspective reads as the viewer sitting farther back.
        uniforms.eye = Float(Self.eyeDistanceMillimetres / max(params.perspective, 0.25) * perMillimetre)
        uniforms.tilt = Float(params.tilt)
        uniforms.blurSpread = Float(Self.blurSpreadRange * params.blur)
        uniforms.darkening = Float(Self.darkeningPerMillimetreRange * params.shadow / perMillimetre)
        uniforms.corner = Float(cornerRadius)
        uniforms.maxLod = Float(max(0, texture.mipmapLevelCount - 1))
        return uniforms
    }

    private func updateTexture(with commandBuffer: MTLCommandBuffer) {
        frameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        frameLock.unlock()

        guard let frame, let cache = textureCache else { return }

        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, frame, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let source = CVMetalTextureGetTexture(cvTexture) else { return }

        if mipTexture?.width != width || mipTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            mipTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let destination = mipTexture, let blit = commandBuffer.makeBlitCommandEncoder() else { return }

        blit.copy(from: source,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: destination,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: destination)
        blit.endEncoding()
    }
}
