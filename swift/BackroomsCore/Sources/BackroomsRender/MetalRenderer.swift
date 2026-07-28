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

    /// A material's three GPU maps.
    public struct Material {
        public var albedo: MTLTexture
        public var normal: MTLTexture
        public var roughness: MTLTexture
    }

    /// GPU-side level: one vertex buffer per geometry chunk, plus the floor
    /// and ceiling planes, and the three materials they are drawn with.
    public struct LevelScene {
        public var chunkBuffers: [(buffer: MTLBuffer, vertexCount: Int)] = []
        public var floor: (buffer: MTLBuffer, vertexCount: Int)?
        public var ceiling: (buffer: MTLBuffer, vertexCount: Int)?
        public var wallMaterial: Material?
        public var floorMaterial: Material?
        public var ceilingMaterial: Material?

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
    /// Albedo for a scene built without materials (an older `LevelScene`, or a
    /// device where texture allocation failed).
    private var fallbackTexture: MTLTexture?
    /// Near-black, so the entity reads as a silhouette rather than a beige man.
    private var entityTexture: MTLTexture?
    /// Neutral stand-ins for anything drawn without a full material.
    private var flatNormalTexture: MTLTexture?
    private var flatRoughTexture: MTLTexture?

    /// Synthesised materials, kept per theme. Generation costs a second or so
    /// of CPU, and a death-and-rewind rebuilds the level — without this cache
    /// every retry would pay for the same wallpaper again.
    private var materialCache: [LevelSpec.Theme: (wall: Material, floor: Material, ceiling: Material)] = [:]

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
        // (0,0,1) in tangent space encodes to (128,128,255).
        flatNormalTexture = makeSolidTexture(r: 128, g: 128, b: 255)
        flatRoughTexture = makeSolidTexture(r: 235, g: 235, b: 235)

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
    ///
    /// Texture synthesis runs on the CPU here and takes a few hundred
    /// milliseconds — it belongs behind a loading screen, not on a frame.
    public func makeScene(map: GameMap, geometry: LevelGeometry) -> LevelScene {
        var scene = LevelScene()
        for mesh in InterleavedMesh.chunks(of: geometry) {
            if let entry = upload(mesh) { scene.chunkBuffers.append(entry) }
        }
        let spec = map.spec
        let span = Double(map.grid) * spec.cellSize
        let tiles = ProceduralTextures.tileScales(spec.theme)

        // Each plane repeats at its own real-world scale, so carpet pile and
        // ceiling tiles stay the size they are in the web build.
        scene.floor = upload(InterleavedMesh.groundPlane(
            map: map, y: 0, flipNormal: false, uvRepeat: Float(span / tiles.floor)))
        scene.ceiling = upload(InterleavedMesh.groundPlane(
            map: map, y: Float(spec.wallHeight), flipNormal: true,
            uvRepeat: Float(span / tiles.ceiling)))

        if let cached = materialCache[spec.theme] {
            scene.wallMaterial = cached.wall
            scene.floorMaterial = cached.floor
            scene.ceilingMaterial = cached.ceiling
            return scene
        }

        let theme = ProceduralTextures.forTheme(spec.theme)
        scene.wallMaterial = makeMaterial(theme.wall)
        // The pool floor is the wall tile, tinted colder on the CPU rather than
        // via a uniform — it keeps the fixture-pinned uniform layout untouched.
        scene.floorMaterial = theme.floorIsTinted
            ? makeMaterial(theme.floor, tintR: theme.floorTintR,
                           tintG: theme.floorTintG, tintB: theme.floorTintB)
            : makeMaterial(theme.floor)
        scene.ceilingMaterial = makeMaterial(theme.ceiling)
        if let w = scene.wallMaterial, let f = scene.floorMaterial, let c = scene.ceilingMaterial {
            materialCache[spec.theme] = (w, f, c)
        }
        return scene
    }

    private func makeMaterial(_ set: SurfaceTextures, tintR: Double = 1,
                              tintG: Double = 1, tintB: Double = 1) -> Material? {
        var albedoBytes = set.albedo
        if tintR != 1 || tintG != 1 || tintB != 1 {
            for i in stride(from: 0, to: albedoBytes.count, by: 4) {
                albedoBytes[i] = UInt8(min(255, Double(albedoBytes[i]) * tintR))
                albedoBytes[i + 1] = UInt8(min(255, Double(albedoBytes[i + 1]) * tintG))
                albedoBytes[i + 2] = UInt8(min(255, Double(albedoBytes[i + 2]) * tintB))
            }
        }
        guard let albedo = makeTexture(albedoBytes, size: set.size,
                                       format: .rgba8Unorm_srgb, bytesPerPixel: 4),
              let normal = makeTexture(set.normal, size: set.size,
                                       format: .rgba8Unorm, bytesPerPixel: 4),
              let rough = makeTexture(set.roughness, size: set.size,
                                      format: .r8Unorm, bytesPerPixel: 1)
        else { return nil }
        return Material(albedo: albedo, normal: normal, roughness: rough)
    }

    /// Uploads level 0 and generates the mip chain on the GPU. Mips are not
    /// optional here: these sheets repeat dozens of times across a floor, so
    /// without them the far end of a corridor aliases into noise.
    private func makeTexture(_ bytes: [UInt8], size: Int,
                             format: MTLPixelFormat, bytesPerPixel: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // .private storage needs a staging blit, which is also where the mips
        // get built.
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size, height: size, mipmapped: false)
        stagingDesc.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: stagingDesc) else { return nil }
        staging.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: size * bytesPerPixel)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
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

        /// Binds a material, or the flat stand-ins if the level was built
        /// before textures existed.
        func bind(_ material: Material?) {
            if let material {
                encoder.setFragmentTexture(material.albedo, index: 0)
                encoder.setFragmentTexture(material.normal, index: 1)
                encoder.setFragmentTexture(material.roughness, index: 2)
            } else {
                encoder.setFragmentTexture(fallbackTexture, index: 0)
                encoder.setFragmentTexture(flatNormalTexture, index: 1)
                encoder.setFragmentTexture(flatRoughTexture, index: 2)
            }
        }

        bind(scene.wallMaterial)
        for (buffer, count) in scene.chunkBuffers {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        for (plane, material) in [(scene.floor, scene.floorMaterial),
                                  (scene.ceiling, scene.ceilingMaterial)] {
            guard let plane else { continue }
            bind(material)
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
            // Its boxes are rotated, so the level's axis-aligned tangent frame
            // does not apply — give it a flat normal and a matte roughness.
            encoder.setFragmentTexture(flatNormalTexture, index: 1)
            encoder.setFragmentTexture(flatRoughTexture, index: 2)
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
