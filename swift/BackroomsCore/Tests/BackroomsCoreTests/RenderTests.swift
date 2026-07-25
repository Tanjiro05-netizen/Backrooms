import XCTest
import simd
@testable import BackroomsCore
@testable import BackroomsRender

/// Covers the renderer's CPU side — buffer layout, mesh interleaving, uniform
/// packing. Actual draw calls need a GPU and a surface, so those are exercised
/// by running the app; what is tested here is everything that can silently
/// corrupt a frame without crashing: wrong strides, mismatched struct layout,
/// dropped vertices.
final class RenderTests: XCTestCase {

    // MARK: - Uniform layout

    /// If this drifts from `SceneUniforms` in Shaders.metal, the GPU reads
    /// garbage — lights in the wrong place, fog density read as a colour.
    func testUniformBufferMatchesShaderLayout() {
        // 1 float4x4 + 9 float4 + 8 lights × 2 float4 = 16 + 36 + 64 floats.
        let expectedFloats = 16 + 9 * 4 + SceneUniforms.maxPointLights * 2 * 4
        let u = SceneUniforms()
        XCTAssertEqual(u.packed().count, expectedFloats)
        XCTAssertEqual(SceneUniforms.bufferLength, expectedFloats * MemoryLayout<Float>.size)
    }

    func testPackedUniformsPlaceFieldsWhereTheShaderExpects() {
        var u = SceneUniforms()
        u.viewProjection = SceneUniforms.matrix(from: Mat4.identity)
        u.cameraPos = SIMD4(1, 2, 3, 0)
        u.fogColor = SIMD4(0.5, 0.25, 0.125, 4.6)   // w = wall height
        u.misc.x = 3
        let p = u.packed()
        // viewProjection occupies floats 0..<16; identity has 1s on the diagonal.
        XCTAssertEqual(p[0], 1); XCTAssertEqual(p[5], 1)
        XCTAssertEqual(p[10], 1); XCTAssertEqual(p[15], 1)
        // cameraPos is the first float4 after the matrix.
        XCTAssertEqual(p[16], 1); XCTAssertEqual(p[17], 2); XCTAssertEqual(p[18], 3)
        // fogColor is the 6th float4 after the matrix (index 16 + 5*4).
        XCTAssertEqual(p[36], 0.5, accuracy: 1e-6)
        XCTAssertEqual(p[39], 4.6, accuracy: 1e-6, "wall height rides in fogColor.w")
        // misc is the 9th (index 16 + 8*4).
        XCTAssertEqual(p[48], 3)
    }

    func testCameraFeedsUniforms() {
        var cam = Camera()
        cam.x = 5; cam.y = 1.62; cam.z = -3; cam.yaw = 0
        var u = SceneUniforms()
        u.apply(camera: cam)
        XCTAssertEqual(u.cameraPos.x, 5)
        XCTAssertEqual(u.cameraPos.z, -3)
        // yaw 0 looks down −Z.
        XCTAssertEqual(u.cameraForward.z, -1, accuracy: 1e-6)
    }

    // MARK: - Mesh interleaving

    func testInterleavingPreservesEveryVertex() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[0], levelIndex: 0)
        let geo = LevelGeometry.build(map: map)
        let meshes = InterleavedMesh.chunks(of: geo)
        XCTAssertFalse(meshes.isEmpty, "level 0 must produce wall geometry")

        let sourceVerts = geo.wallChunks.compactMap { $0 }.reduce(0) { $0 + $1.vertexCount }
        let interleavedVerts = meshes.reduce(0) { $0 + $1.vertexCount }
        XCTAssertEqual(interleavedVerts, sourceVerts)
        XCTAssertEqual(InterleavedMesh.stride, 32, "8 floats per vertex")
    }

    /// Spot-check that position/normal/uv land in the right slots — a
    /// transposed field here would skew every wall in the game.
    func testInterleavedVertexFieldsAreInOrder() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[0], levelIndex: 0)
        let geo = LevelGeometry.build(map: map)
        let chunk = try! XCTUnwrap(geo.wallChunks.compactMap { $0 }.first)
        let mesh = InterleavedMesh(chunk)
        for i in 0..<min(4, mesh.vertexCount) {
            let base = i * InterleavedMesh.floatsPerVertex
            XCTAssertEqual(mesh.vertices[base + 0], chunk.positions[i * 3 + 0])
            XCTAssertEqual(mesh.vertices[base + 1], chunk.positions[i * 3 + 1])
            XCTAssertEqual(mesh.vertices[base + 2], chunk.positions[i * 3 + 2])
            XCTAssertEqual(mesh.vertices[base + 3], chunk.normals[i * 3 + 0])
            XCTAssertEqual(mesh.vertices[base + 5], chunk.normals[i * 3 + 2])
            XCTAssertEqual(mesh.vertices[base + 6], chunk.uvs[i * 2 + 0])
            XCTAssertEqual(mesh.vertices[base + 7], chunk.uvs[i * 2 + 1])
        }
    }

    func testGroundPlanesCoverTheLevelAndFaceEachOther() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[1], levelIndex: 1)
        let half = Float(Double(map.grid) * map.spec.cellSize / 2)
        let floor = InterleavedMesh.groundPlane(map: map, y: 0, flipNormal: false, uvRepeat: 4)
        let ceil = InterleavedMesh.groundPlane(map: map, y: Float(map.spec.wallHeight),
                                               flipNormal: true, uvRepeat: 4)
        XCTAssertEqual(floor.vertexCount, 6)
        XCTAssertEqual(ceil.vertexCount, 6)
        // Floor normal points up, ceiling normal points down.
        XCTAssertEqual(floor.vertices[4], 1)
        XCTAssertEqual(ceil.vertices[4], -1)
        // Corners reach the level bounds.
        XCTAssertEqual(abs(floor.vertices[0]), half, accuracy: 1e-3)
    }

    // MARK: - Lights

    func testNearestLightsAreLoadedAndBounded() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[0], levelIndex: 0)
        var u = SceneUniforms()
        let px = map.cellWorldX(map.spawnX), pz = map.cellWorldZ(map.spawnZ)
        u.loadNearestLights(from: map, playerX: px, playerZ: pz, lightY: 3.0,
                            color: SIMD3(1, 0.9, 0.7), intensity: 1.15, range: 13.5)

        XCTAssertLessThanOrEqual(Int(u.misc.x), SceneUniforms.maxPointLights)
        XCTAssertGreaterThan(Int(u.misc.x), 0, "level 0 is full of fixtures")
        XCTAssertEqual(u.pointLights.count, SceneUniforms.maxPointLights)

        // The chosen lights really are the closest ones.
        let chosen = (0..<Int(u.misc.x)).map { i -> Double in
            let l = u.pointLights[i].positionRange
            let dx = Double(l.x) - px, dz = Double(l.z) - pz
            return (dx * dx + dz * dz).squareRoot()
        }
        let allDistances = map.fixtures.map { f -> Double in
            let dx = map.cellWorldX(f.cellX) - px, dz = map.cellWorldZ(f.cellZ) - pz
            return (dx * dx + dz * dz).squareRoot()
        }.sorted()
        for (i, d) in chosen.enumerated() {
            XCTAssertEqual(d, allDistances[i], accuracy: 1e-6, "light \(i) is not the \(i)th nearest")
        }
        XCTAssertEqual(u.pointLights[0].positionRange.w, 13.5)
    }
}
