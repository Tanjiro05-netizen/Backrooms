#if canImport(Metal)
import Metal
import Foundation
import Dispatch
import BackroomsCore

/// The native forward renderer.
///
/// It owns no game state: hand it a `LevelScene` (GPU buffers built from the
/// core's byte-exact geometry) plus per-frame `SceneUniforms`, and it draws.
/// That keeps the simulation testable on any machine and the rendering
/// replaceable without touching gameplay.
public final class MetalRenderer {

    /// GPU-side level: one vertex buffer per geometry chunk, plus the floor
    /// and ceiling planes.
    public struct LevelScene {
        public var chunkBuffers: [(buffer: MTLBuffer, vertexCount: Int)] = []
        public var floor: (buffer: MTLBuffer, vertexCount: Int)?
        public var ceiling: (buffer: MTLBuffer, vertexCount: Int)?

        public var totalVertices: Int {
            chunkBuffers.reduce(0) { $0 + $1.vertexCount }
                + (floor?.vertexCount ?? 0) + (ceiling?.vertexCount ?? 0)
        }
    }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var samplerState: MTLSamplerState?
    /// Stand-in albedo until the procedural texture generators are ported.
    private var fallbackTexture: MTLTexture?
    /// Near-black, so the entity reads as a silhouette rather than a beige man.
    private var entityTexture: MTLTexture?

    /// Ring of scratch buffers for geometry that changes every frame (the
    /// entity). Three deep because `MTKView` keeps at most three frames in
    /// flight, and the semaphore stops the CPU lapping the GPU and overwriting
    /// a buffer still being read.
    private var dynamicBuffers: [MTLBuffer] = []
    private var dynamicIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private static let framesInFlight = 3
    private static let dynamicCapacityFloats = 24_576   // 3072 vertices

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
    }

    // MARK: - Setup

    /// Compiles the shaders and builds the pipeline.
    ///
    /// The `.metal` source ships as a package resource and is compiled at
    /// runtime rather than pre-built into a metallib: it keeps the package
    /// buildable by plain `swift build` on any machine, which is what lets CI
    /// verify this code without an Xcode app target.
    public func prepare(colorFormat: MTLPixelFormat = .bgra8Unorm,
                        depthFormat: MTLPixelFormat = .depth32Float) throws {
        let library = try makeLibrary()
        guard let vertexFn = library.makeFunction(name: "level_vertex"),
              let fragmentFn = library.makeFunction(name: "level_fragment") else {
            throw RendererError.missingShaderFunction
        }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3          // position
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3          // normal
        vd.attributes[1].offset = MemoryLayout<Float>.size * 3
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2          // uv
        vd.attributes[2].offset = MemoryLayout<Float>.size * 6
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = InterleavedMesh.stride

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.vertexDescriptor = vd
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = depthFormat
        pipelineState = try device.makeRenderPipelineState(descriptor: desc)

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDesc)

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.mipFilter = .linear
        sampDesc.sAddressMode = .repeat
        sampDesc.tAddressMode = .repeat
        sampDesc.maxAnisotropy = 8
        samplerState = device.makeSamplerState(descriptor: sampDesc)

        fallbackTexture = makeSolidTexture(r: 186, g: 174, b: 128)
        entityTexture = makeSolidTexture(r: 26, g: 24, b: 24)

        dynamicBuffers = (0..<MetalRenderer.framesInFlight).compactMap { _ in
            device.makeBuffer(length: MetalRenderer.dynamicCapacityFloats * MemoryLayout<Float>.size,
                              options: .storageModeShared)
        }
    }

    /// Prefers the precompiled default library — which is what exists when the
    /// `.metal` file is a source in an app target — and falls back to compiling
    /// the shipped `.metal` resource at runtime, which is how the package
    /// builds standalone (and how CI verifies this target without an app).
    private func makeLibrary() throws -> MTLLibrary {
        if let precompiled = device.makeDefaultLibrary(),
           precompiled.makeFunction(name: "level_vertex") != nil {
            return precompiled
        }
        for bundle in [Bundle.module, Bundle.main] {
            if let url = bundle.url(forResource: "Shaders", withExtension: "metal"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                return try device.makeLibrary(source: source, options: nil)
            }
        }
        throw RendererError.missingShaderSource
    }

    /// A flat colour stand-in until `genWallpaper`/`genCarpet` and friends are
    /// ported; lighting and fog still read correctly against it.
    private func makeSolidTexture(r: UInt8, g: UInt8, b: UInt8) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var pixels = [UInt8]()
        for _ in 0..<16 { pixels.append(contentsOf: [r, g, b, 255]) }
        tex.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: 4 * 4)
        return tex
    }

    // MARK: - Level upload

    /// Uploads a generated level to the GPU once; nothing here changes per frame.
    public func makeScene(map: GameMap, geometry: LevelGeometry) -> LevelScene {
        var scene = LevelScene()
        for mesh in InterleavedMesh.chunks(of: geometry) {
            if let entry = upload(mesh) { scene.chunkBuffers.append(entry) }
        }
        let spec = map.spec
        let floorRepeat = Float(Double(map.grid) * spec.cellSize / 2.4)
        scene.floor = upload(InterleavedMesh.groundPlane(
            map: map, y: 0, flipNormal: false, uvRepeat: floorRepeat))
        scene.ceiling = upload(InterleavedMesh.groundPlane(
            map: map, y: Float(spec.wallHeight), flipNormal: true, uvRepeat: floorRepeat))
        return scene
    }

    private func upload(_ mesh: InterleavedMesh) -> (MTLBuffer, Int)? {
        guard !mesh.isEmpty else { return nil }
        let bytes = mesh.vertices.count * MemoryLayout<Float>.size
        guard let buf = device.makeBuffer(bytes: mesh.vertices, length: bytes,
                                          options: .storageModeShared) else { return nil }
        return (buf, mesh.vertexCount)
    }

    // MARK: - Draw

    /// Encodes one frame. The caller supplies the render pass (from an
    /// `MTKView`'s current descriptor, say) and the drawable to present.
    /// `entity`, when present, is world-space geometry rebuilt this frame.
    public func draw(scene: LevelScene, uniforms: SceneUniforms,
                     entity: InterleavedMesh? = nil,
                     passDescriptor: MTLRenderPassDescriptor,
                     drawable: MTLDrawable?) {
        guard let pipelineState else { return }
        inFlight.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        commandBuffer.addCompletedHandler { [sem = inFlight] _ in sem.signal() }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        if let depthState { encoder.setDepthStencilState(depthState) }
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        var packed = uniforms.packed()
        encoder.setVertexBytes(&packed, length: packed.count * MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&packed, length: packed.count * MemoryLayout<Float>.size, index: 1)
        if let samplerState { encoder.setFragmentSamplerState(samplerState, index: 0) }
        if let fallbackTexture { encoder.setFragmentTexture(fallbackTexture, index: 0) }

        for (buffer, count) in scene.chunkBuffers {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        for plane in [scene.floor, scene.ceiling] {
            guard let plane else { continue }
            encoder.setVertexBuffer(plane.buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plane.vertexCount)
        }

        // The entity last, on its own dark albedo, and double-sided: its limbs
        // are thin enough that a back-face cull leaves visible holes when the
        // camera is close.
        if let entity, !entity.isEmpty, !dynamicBuffers.isEmpty,
           entity.vertices.count <= MetalRenderer.dynamicCapacityFloats,
           let entityTexture {
            let buffer = dynamicBuffers[dynamicIndex]
            dynamicIndex = (dynamicIndex + 1) % dynamicBuffers.count
            entity.vertices.withUnsafeBytes { src in
                buffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            encoder.setCullMode(.none)
            encoder.setFragmentTexture(entityTexture, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: entity.vertexCount)
        }

        encoder.endEncoding()
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }

    public enum RendererError: Error {
        case missingShaderSource
        case missingShaderFunction
    }
}
#endif
