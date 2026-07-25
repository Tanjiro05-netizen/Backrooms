import Foundation
import BackroomsCore

/// Interleaves the core's separate position/normal/uv arrays into the single
/// vertex stream a GPU wants.
///
/// `BackroomsCore` deliberately emits parallel arrays because that is what the
/// web build produces and what the byte-exact fixtures pin. Interleaving is a
/// rendering concern, so it happens here — one 32-byte vertex, which keeps a
/// whole triangle inside two cache lines.
public struct InterleavedMesh {
    /// Layout per vertex: position(3) + normal(3) + uv(2) = 8 floats.
    public static let floatsPerVertex = 8
    public static let stride = floatsPerVertex * MemoryLayout<Float>.size

    public let vertices: [Float]
    public var vertexCount: Int { vertices.count / InterleavedMesh.floatsPerVertex }
    public var isEmpty: Bool { vertices.isEmpty }

    public init(_ buffer: LevelGeometry.MeshBuffer) {
        let n = buffer.vertexCount
        var v = [Float]()
        v.reserveCapacity(n * InterleavedMesh.floatsPerVertex)
        for i in 0..<n {
            v.append(buffer.positions[i * 3 + 0])
            v.append(buffer.positions[i * 3 + 1])
            v.append(buffer.positions[i * 3 + 2])
            v.append(buffer.normals[i * 3 + 0])
            v.append(buffer.normals[i * 3 + 1])
            v.append(buffer.normals[i * 3 + 2])
            v.append(buffer.uvs[i * 2 + 0])
            v.append(buffer.uvs[i * 2 + 1])
        }
        self.vertices = v
    }

    /// Builds one interleaved mesh per non-empty geometry chunk. Chunking is
    /// inherited from the level generator, and keeping it means the renderer
    /// can cull whole 8×8-cell blocks later rather than drawing the floor twice.
    public static func chunks(of geometry: LevelGeometry) -> [InterleavedMesh] {
        geometry.wallChunks.compactMap { chunk in
            guard let chunk, !chunk.isEmpty else { return nil }
            return InterleavedMesh(chunk)
        }
    }

    /// A floor or ceiling quad spanning the whole level, matching the web
    /// build's two big planes. `y` is the height; `flipNormal` faces it down
    /// for the ceiling. UVs repeat so the tiling texture keeps its real-world
    /// scale instead of stretching across the map.
    public static func groundPlane(map: GameMap, y: Float, flipNormal: Bool,
                                   uvRepeat: Float) -> InterleavedMesh {
        let half = Float(Double(map.grid) * map.spec.cellSize / 2)
        let ny: Float = flipNormal ? -1 : 1
        let r = uvRepeat
        let zero: Float = 0

        // The four corners, each carrying its uv.
        let bl = (x: -half, z: -half, u: zero, v: zero)   // back-left
        let br = (x:  half, z: -half, u: r,    v: zero)
        let fl = (x: -half, z:  half, u: zero, v: r)
        let fr = (x:  half, z:  half, u: r,    v: r)

        // Two triangles, wound so the visible face points at the player: the
        // ceiling faces down, the floor faces up, so their winding is opposite.
        let corners = flipNormal ? [bl, fl, fr, bl, fr, br]
                                 : [bl, fr, fl, bl, br, fr]

        var verts = [Float]()
        verts.reserveCapacity(corners.count * floatsPerVertex)
        for c in corners {
            verts.append(contentsOf: [c.x, y, c.z, zero, ny, zero, c.u, c.v])
        }
        return InterleavedMesh(rawVertices: verts)
    }

    init(rawVertices: [Float]) { self.vertices = rawVertices }
}
