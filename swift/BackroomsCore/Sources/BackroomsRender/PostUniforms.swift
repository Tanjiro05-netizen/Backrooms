#if canImport(Metal)
import Foundation
import simd

/// Uniforms for the screen-space passes that have to un-project the depth
/// buffer — SSAO and the volumetrics.
///
/// Deliberately its own buffer rather than extra fields on `SceneUniforms`:
/// that struct's byte layout is asserted against the MSL side in tests, and
/// growing it to carry data only two post passes need would churn the contract
/// every renderer feature touches.
public struct PostUniforms: Equatable {

    /// Clip → world, for rebuilding a world position from a depth sample.
    public var invViewProjection: matrix_float4x4 = matrix_identity_float4x4
    /// World → clip, for projecting a sampled point back onto the screen.
    public var viewProjection: matrix_float4x4 = matrix_identity_float4x4
    /// SSAO: x = radius in metres, y = strength, z/w = source texel size.
    /// Volumetrics: x = density, y = unused, z = march cap in metres, w spare.
    public var params = SIMD4<Float>(0, 0, 0, 0)
    /// xyz = camera world position.
    public var camera = SIMD4<Float>(0, 0, 0, 0)

    public init() {}

    /// Two 4×4s plus two float4s.
    public static let floatCount = 16 * 2 + 4 * 2

    public func packed() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(PostUniforms.floatCount)
        for matrix in [invViewProjection, viewProjection] {
            // Column-major on both sides, same as `SceneUniforms.packed`.
            for c in 0..<4 {
                let col = matrix[c]
                out.append(contentsOf: [col.x, col.y, col.z, col.w])
            }
        }
        for v in [params, camera] {
            out.append(contentsOf: [v.x, v.y, v.z, v.w])
        }
        return out
    }
}
#endif
