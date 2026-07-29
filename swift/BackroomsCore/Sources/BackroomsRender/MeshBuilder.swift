import Foundation

/// Accumulates interleaved world-space vertices.
///
/// The level shader takes no model matrix — level geometry is authored in world
/// space — so anything that moves or gets rebuilt (the entity, tapes, the exit
/// door) is emitted already transformed. This is the shared box emitter for all
/// of them: one place that knows the winding, the normal rotation and the
/// vertex layout.
public struct MeshBuilder {
    public private(set) var vertices: [Float] = []

    public init(reservingBoxes count: Int = 0) {
        vertices.reserveCapacity(count * 36 * InterleavedMesh.floatsPerVertex)
    }

    /// The six faces of a unit cube, wound counter-clockwise when seen from
    /// outside, with the outward normal and a corner sign per vertex.
    private static let faces: [(n: (Float, Float, Float), corners: [(Float, Float, Float)])] = [
        ((0, 0, 1),  [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
        ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
        ((1, 0, 0),  [(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, -1, 1), (1, 1, -1), (1, 1, 1)]),
        ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, -1, -1), (-1, 1, 1), (-1, 1, -1)]),
        ((0, 1, 0),  [(-1, 1, 1), (1, 1, 1), (1, 1, -1), (-1, 1, 1), (1, 1, -1), (-1, 1, -1)]),
        ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, -1), (1, -1, 1), (-1, -1, 1)])
    ]

    /// Vertices per box, so callers can assert what they emitted.
    public static let verticesPerBox = 36

    /// Adds a box whose centre is `local` in a frame rotated by `yaw` about Y
    /// and then translated to `origin`. `yaw` follows the camera convention:
    /// 0 faces −Z.
    public mutating func addBox(originX: Float, originY: Float, originZ: Float,
                                yaw: Float,
                                localX: Float, localY: Float, localZ: Float,
                                halfX: Float, halfY: Float, halfZ: Float,
                                u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1) {
        let c = cosf(yaw), s = sinf(yaw)
        for face in MeshBuilder.faces {
            let nx = face.n.0 * c + face.n.2 * s
            let nz = -face.n.0 * s + face.n.2 * c
            for corner in face.corners {
                let lx = localX + corner.0 * halfX
                let ly = localY + corner.1 * halfY
                let lz = localZ + corner.2 * halfZ
                let wx = originX + (lx * c + lz * s)
                let wz = originZ + (-lx * s + lz * c)
                let u = u0 + (corner.0 + 1) * 0.5 * (u1 - u0)
                let v = v0 + (corner.1 + 1) * 0.5 * (v1 - v0)
                vertices.append(contentsOf: [wx, originY + ly, wz, nx, face.n.1, nz, u, v])
            }
        }
    }

    public var isEmpty: Bool { vertices.isEmpty }
    public var mesh: InterleavedMesh { InterleavedMesh(rawVertices: vertices) }
}
