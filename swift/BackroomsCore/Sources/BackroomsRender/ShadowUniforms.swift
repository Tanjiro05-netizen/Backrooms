#if canImport(Metal)
import Foundation
import simd
import BackroomsCore

/// What the scene shader needs to test a fragment against the shadow map.
///
/// Its own buffer rather than fields on `SceneUniforms`, whose byte layout is
/// asserted against the MSL struct in tests — the same reasoning as
/// `PostUniforms`.
public struct ShadowUniforms: Equatable {

    /// World → the shadow camera's clip space.
    public var lightViewProjection: matrix_float4x4 = matrix_identity_float4x4
    /// x = enabled (0 disables the lookup entirely), y = depth bias,
    /// z = texel size in UV, w = strength.
    public var params = SIMD4<Float>(0, 0, 0, 0)

    public init() {}

    public static let floatCount = 16 + 4

    public func packed() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(ShadowUniforms.floatCount)
        for c in 0..<4 {
            let col = lightViewProjection[c]
            out.append(contentsOf: [col.x, col.y, col.z, col.w])
        }
        out.append(contentsOf: [params.x, params.y, params.z, params.w])
        return out
    }

    /// Resolution of the depth map. 1024 over a 15m square is a texel of about
    /// 15mm, which is finer than the contact shadows underneath it and far
    /// cheaper than it sounds for a single depth-only pass.
    public static let mapSize = 1024
    /// Half-width of the area the map covers, in metres.
    public static let halfExtent: Float = 7.5
    /// Depth bias at normal incidence; scaled up for grazing surfaces in the
    /// shader. Too little stripes every wall with acne, too much lifts the
    /// shadow off the floor it belongs to.
    public static let bias: Float = 0.0016
    /// How dark a fully shadowed fragment goes. Not 1.0: a ceiling panel is a
    /// broad source, and a shadow under one in a room with seven other
    /// fixtures and a wash of ambient is never black.
    public static let strength: Float = 0.78

    /// Build the shadow camera for a fixture at this world position.
    ///
    /// `near` starts just below the panel so the fixture's own housing does
    /// not fill the map, and `far` reaches past the floor.
    public static func forFixture(x: Float, y: Float, z: Float) -> ShadowUniforms {
        var out = ShadowUniforms()
        let projection = Mat4.orthographicMetal(halfExtent: halfExtent,
                                                near: 0.05, far: y + 1.5)
        let view = Mat4.lookingDown(x: x, y: y, z: z)
        out.lightViewProjection = SceneUniforms.matrix(from: projection.multiplied(by: view))
        out.params = SIMD4<Float>(1, bias, 1 / Float(mapSize), strength)
        return out
    }
}
#endif
