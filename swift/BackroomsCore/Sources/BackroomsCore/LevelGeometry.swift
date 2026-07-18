import Foundation

/// Port of the web build's wall-geometry emitters (`pushQuad`, `faceZ`,
/// `faceX`, `faceYDown`, `wallBox`, `buildWallEdge`, `buildPillar`) and the
/// collider-bucket system. Vertices are computed in Double (JS number math)
/// and stored as Float — the same rounding the JS `Float32Array` upload does,
/// so the buffers are byte-identical to the web renderer's.
public struct LevelGeometry: Sendable {

    /// Wall thickness (`WT`) and chunk span (`CHUNK`) from the web build.
    public static let wallThickness = 0.24
    public static let chunkSpan = 8

    /// One renderable vertex-array bundle (non-indexed triangles).
    public struct MeshBuffer: Sendable {
        public var positions: [Float] = []
        public var normals: [Float] = []
        public var uvs: [Float] = []
        public var vertexCount: Int { positions.count / 3 }
        public var isEmpty: Bool { positions.isEmpty }

        mutating func pushQuad(_ ax: Double, _ ay: Double, _ az: Double,
                               _ bx: Double, _ by: Double, _ bz: Double,
                               _ cx: Double, _ cy: Double, _ cz: Double,
                               _ dx: Double, _ dy: Double, _ dz: Double,
                               _ nx: Double, _ ny: Double, _ nz: Double,
                               _ ua: Double, _ va: Double, _ ub: Double, _ vb: Double,
                               _ uc: Double, _ vc: Double, _ ud: Double, _ vd: Double) {
            positions.append(contentsOf: [
                Float(ax), Float(ay), Float(az), Float(bx), Float(by), Float(bz),
                Float(cx), Float(cy), Float(cz), Float(ax), Float(ay), Float(az),
                Float(cx), Float(cy), Float(cz), Float(dx), Float(dy), Float(dz)])
            for _ in 0..<6 { normals.append(contentsOf: [Float(nx), Float(ny), Float(nz)]) }
            uvs.append(contentsOf: [
                Float(ua), Float(va), Float(ub), Float(vb), Float(uc), Float(vc),
                Float(ua), Float(va), Float(uc), Float(vc), Float(ud), Float(vd)])
        }
    }

    /// Axis-aligned collision rectangle in world space (x0, z0, x1, z1).
    public struct ColliderRect: Sendable, Equatable {
        public let x0: Double, z0: Double, x1: Double, z1: Double
    }

    /// Wall geometry per chunk (nil where a chunk received no geometry, to
    /// mirror the JS sparse array) and colliders bucketed by cell key
    /// (`cx + cz*grid`), duplicated per covered cell exactly like the web build.
    public let wallChunks: [MeshBuffer?]
    public let colliderBuckets: [Int: [ColliderRect]]
    public let chunksPerSide: Int

    // MARK: - Build

    public static func build(map: GameMap) -> LevelGeometry {
        let spec = map.spec
        let gw = spec.grid, gh = spec.grid
        let cs = spec.cellSize, wh = spec.wallHeight
        let uvs = spec.uvScale, vvs = spec.vScale
        let ht = wallThickness / 2
        let nCx = Int(ceil(Double(gw) / Double(chunkSpan)))

        var chunks = [MeshBuffer?](repeating: nil, count: nCx * nCx)
        var maxChunkIndex = -1
        var buckets: [Int: [ColliderRect]] = [:]

        func chunkIdx(_ cellX: Int, _ cellZ: Int) -> Int {
            let cx = min(nCx - 1, max(0, cellX) / chunkSpan)
            let cz = min(nCx - 1, max(0, cellZ) / chunkSpan)
            return cx + cz * nCx
        }

        func addCollider(_ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double) {
            let c0 = max(0, map.worldToCellX(x0)), c1 = min(gw - 1, map.worldToCellX(x1))
            let d0 = max(0, map.worldToCellZ(z0)), d1 = min(gh - 1, map.worldToCellZ(z1))
            guard c0 <= c1, d0 <= d1 else { return }
            let rect = ColliderRect(x0: x0, z0: z0, x1: x1, z1: z1)
            for cz in d0...d1 { for cx in c0...c1 {
                buckets[cx + cz * gw, default: []].append(rect)
            } }
        }

        func withChunk(_ index: Int, _ body: (inout MeshBuffer) -> Void) {
            if chunks[index] == nil { chunks[index] = MeshBuffer() }
            maxChunkIndex = max(maxChunkIndex, index)
            body(&chunks[index]!)
        }

        func faceZ(_ a: inout MeshBuffer, _ x0: Double, _ x1: Double,
                   _ y0: Double, _ y1: Double, _ z: Double, _ sign: Double) {
            if sign > 0 {
                a.pushQuad(x0, y0, z, x1, y0, z, x1, y1, z, x0, y1, z, 0, 0, 1,
                           x0 / uvs, y0 / vvs, x1 / uvs, y0 / vvs, x1 / uvs, y1 / vvs, x0 / uvs, y1 / vvs)
            } else {
                a.pushQuad(x1, y0, z, x0, y0, z, x0, y1, z, x1, y1, z, 0, 0, -1,
                           x1 / uvs, y0 / vvs, x0 / uvs, y0 / vvs, x0 / uvs, y1 / vvs, x1 / uvs, y1 / vvs)
            }
        }
        func faceX(_ a: inout MeshBuffer, _ z0: Double, _ z1: Double,
                   _ y0: Double, _ y1: Double, _ x: Double, _ sign: Double) {
            if sign > 0 {
                a.pushQuad(x, y0, z1, x, y0, z0, x, y1, z0, x, y1, z1, 1, 0, 0,
                           z1 / uvs, y0 / vvs, z0 / uvs, y0 / vvs, z0 / uvs, y1 / vvs, z1 / uvs, y1 / vvs)
            } else {
                a.pushQuad(x, y0, z0, x, y0, z1, x, y1, z1, x, y1, z0, -1, 0, 0,
                           z0 / uvs, y0 / vvs, z1 / uvs, y0 / vvs, z1 / uvs, y1 / vvs, z0 / uvs, y1 / vvs)
            }
        }
        func faceYDown(_ a: inout MeshBuffer, _ x0: Double, _ x1: Double,
                       _ z0: Double, _ z1: Double, _ y: Double) {
            a.pushQuad(x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1, 0, -1, 0,
                       x0 / uvs, 0.62, x1 / uvs, 0.62, x1 / uvs, 0.66, x0 / uvs, 0.66)
        }
        func wallBox(_ a: inout MeshBuffer, alongX: Bool, _ a0: Double, _ a1: Double,
                     _ fixed: Double, _ y0: Double, _ y1: Double) {
            if alongX {
                faceZ(&a, a0, a1, y0, y1, fixed + ht, 1)
                faceZ(&a, a0, a1, y0, y1, fixed - ht, -1)
                faceX(&a, fixed - ht, fixed + ht, y0, y1, a0, -1)
                faceX(&a, fixed - ht, fixed + ht, y0, y1, a1, 1)
                if y0 > 0.01 { faceYDown(&a, a0, a1, fixed - ht, fixed + ht, y0) }
                if y0 < 0.01 { addCollider(a0, fixed - ht, a1, fixed + ht) }
            } else {
                faceX(&a, a0, a1, y0, y1, fixed + ht, 1)
                faceX(&a, a0, a1, y0, y1, fixed - ht, -1)
                faceZ(&a, fixed - ht, fixed + ht, y0, y1, a0, -1)
                faceZ(&a, fixed - ht, fixed + ht, y0, y1, a1, 1)
                if y0 > 0.01 { faceYDown(&a, fixed - ht, fixed + ht, a0, a1, y0) }
                if y0 < 0.01 { addCollider(fixed - ht, a0, fixed + ht, a1) }
            }
        }
        func buildWallEdge(_ a: inout MeshBuffer, alongX: Bool, _ edgeA: Int, _ edgeB: Int, _ type: UInt8) {
            let a0 = alongX ? (Double(edgeA) - Double(gw) / 2) * cs
                            : (Double(edgeA) - Double(gh) / 2) * cs
            let fixed = alongX ? (Double(edgeB) - Double(gh) / 2) * cs
                               : (Double(edgeB) - Double(gw) / 2) * cs
            if type == 1 {
                wallBox(&a, alongX: alongX, a0, a0 + cs, fixed, 0, wh)
            } else {
                let mid = a0 + cs / 2, g = 0.85, hH = min(2.18, wh - 0.5)
                wallBox(&a, alongX: alongX, a0, mid - g, fixed, 0, wh)
                wallBox(&a, alongX: alongX, mid + g, a0 + cs, fixed, 0, wh)
                wallBox(&a, alongX: alongX, mid - g, mid + g, fixed, hH, wh)
            }
        }
        func buildPillar(_ a: inout MeshBuffer, _ wx: Double, _ wz: Double) {
            let h = spec.pillarHalf
            faceZ(&a, wx - h, wx + h, 0, wh, wz + h, 1)
            faceZ(&a, wx - h, wx + h, 0, wh, wz - h, -1)
            faceX(&a, wz - h, wz + h, 0, wh, wx + h, 1)
            faceX(&a, wz - h, wz + h, 0, wh, wx - h, -1)
            addCollider(wx - h, wz - h, wx + h, wz + h)
        }

        // Emission order matches `buildLevelWorld` exactly.
        for z in 0...gh { for x in 0..<gw {
            let tp = map.hWalls[x + z * gw]
            if tp == 0 { continue }
            withChunk(chunkIdx(x, min(z, gh - 1))) { buildWallEdge(&$0, alongX: true, x, z, tp) }
        } }
        for z in 0..<gh { for x in 0...gw {
            let tp = map.vWalls[x + z * (gw + 1)]
            if tp == 0 { continue }
            withChunk(chunkIdx(min(x, gw - 1), z)) { buildWallEdge(&$0, alongX: false, z, x, tp) }
        } }
        for z in 0..<gh { for x in 0..<gw {
            if map.pillarMask[x + z * gw] != 0 {
                withChunk(chunkIdx(x, z)) { buildPillar(&$0, map.cellWorldX(x), map.cellWorldZ(z)) }
            }
        } }

        // JS chunk arrays are sparse with length = highest index + 1.
        let trimmed = maxChunkIndex >= 0 ? Array(chunks[0...maxChunkIndex]) : []
        return LevelGeometry(wallChunks: trimmed, colliderBuckets: buckets, chunksPerSide: nCx)
    }
}
