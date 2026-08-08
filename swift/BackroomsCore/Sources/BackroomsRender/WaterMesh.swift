#if canImport(Metal)
import Foundation
import BackroomsCore

/// Swift mirror of the MSL `WaterUniforms`. All `float4`s, same reasoning as
/// every other uniform block here.
public struct WaterUniforms: Equatable {
    /// x = seconds, y = surface Y, z = absorption depth, w = base opacity.
    public var params = SIMD4<Float>(0, WaterMesh.surfaceY, 1.4, 0.62)
    /// rgb = deep-water colour, w = Fresnel strength. The Poolrooms read as
    /// warm-lit pale green rather than the blue a pool would be outdoors —
    /// the light in there is all fluorescent.
    public var tint = SIMD4<Float>(0.42, 0.66, 0.62, 1.0)

    public init() {}

    public static let floatCount = 8

    public func packed() -> [Float] {
        [params.x, params.y, params.z, params.w,
         tint.x, tint.y, tint.z, tint.w]
    }
}

/// The Poolrooms water surface.
///
/// The web build drops one big plane across the whole floor at y = 0.30 and
/// lets the raised platforms poke through it. That works there because its
/// water is transparent and unsorted; here the surface is alpha-blended with
/// depth-write off, and a plane running underneath every platform would show
/// through the tile as a haze wherever the two nearly touch.
///
/// So this emits water per *water cell* instead — only where `zoneMask` says
/// the floor is at 0, never under the platforms at 0.55. Same look, no
/// z-fighting haze, and a good deal fewer pixels to shade.
public enum WaterMesh {

    /// Matches the web build's `waterMesh.position.y`.
    public static let surfaceY: Float = 0.30
    /// World units per UV tile — the web build's `repeat.set(size / 3.2, …)`.
    public static let uvScale: Float = 3.2

    /// Interleaved position/normal/uv triangles for the water plane, in world
    /// space. Empty for any non-pool level.
    public static func surface(map: GameMap) -> InterleavedMesh {
        guard map.spec.theme == .pool else { return InterleavedMesh(rawVertices: []) }

        let grid = map.grid
        let cell = Float(map.spec.cellSize)
        var verts = [Float]()

        for cz in 0..<grid {
            for cx in 0..<grid {
                guard map.zoneMask[cx + cz * grid] != 0 else { continue }

                let centreX = Float(map.cellWorldX(cx))
                let centreZ = Float(map.cellWorldZ(cz))
                let half = cell * 0.5
                let x0 = centreX - half, x1 = centreX + half
                let z0 = centreZ - half, z1 = centreZ + half

                // Winding copied from `MeshBuilder`'s +Y face so the water
                // agrees with every other up-facing surface in the level:
                // counter-clockwise seen from above, which is what the
                // renderer's back-face cull expects.
                appendVertex(&verts, x0, z1)
                appendVertex(&verts, x1, z1)
                appendVertex(&verts, x1, z0)
                appendVertex(&verts, x0, z1)
                appendVertex(&verts, x1, z0)
                appendVertex(&verts, x0, z0)
            }
        }
        return InterleavedMesh(rawVertices: verts)
    }

    /// UVs come from world position, not from cell corners: the normal maps
    /// scroll across the whole surface, and per-cell UVs would put a visible
    /// seam on every cell boundary.
    private static func appendVertex(_ out: inout [Float], _ x: Float, _ z: Float) {
        out.append(contentsOf: [x, surfaceY, z,
                                0, 1, 0,
                                x / uvScale, z / uvScale])
    }
}
#endif
