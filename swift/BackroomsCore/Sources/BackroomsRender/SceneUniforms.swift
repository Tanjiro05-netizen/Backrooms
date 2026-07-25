import Foundation
import simd
import BackroomsCore

/// Swift mirror of the MSL `PointLightU`. Both sides are pure `float4`s so the
/// layouts cannot silently disagree.
public struct PointLightUniform: Equatable {
    /// xyz = world position, w = range in metres.
    public var positionRange: SIMD4<Float>
    /// rgb = colour, w = intensity.
    public var colorIntensity: SIMD4<Float>

    public init(x: Float, y: Float, z: Float, range: Float,
                color: SIMD3<Float>, intensity: Float) {
        positionRange = SIMD4(x, y, z, range)
        colorIntensity = SIMD4(color.x, color.y, color.z, intensity)
    }

    public static let zero = PointLightUniform(x: 0, y: 0, z: 0, range: 0,
                                               color: .zero, intensity: 0)
}

/// Swift mirror of the MSL `SceneUniforms`. Field order and types must match
/// `Shaders.metal` exactly; `uniformStride` is asserted in tests.
public struct SceneUniforms {
    public static let maxPointLights = 8

    public var viewProjection: matrix_float4x4 = matrix_identity_float4x4
    public var cameraPos = SIMD4<Float>(0, 0, 0, 0)
    public var cameraForward = SIMD4<Float>(0, 0, -1, 0)
    /// rgb = ambient colour, w = intensity.
    public var ambient = SIMD4<Float>(0.36, 0.33, 0.25, 0.5)
    /// rgb = sky colour, w = hemisphere intensity.
    public var hemiSky = SIMD4<Float>(0.45, 0.41, 0.30, 0.45)
    /// rgb = ground colour, w = fog density.
    public var hemiGround = SIMD4<Float>(0.09, 0.07, 0.04, 0.052)
    /// rgb = fog colour, w = wall height (drives the contact-shadow gradient).
    public var fogColor = SIMD4<Float>(0.08, 0.06, 0.04, 3.2)
    /// rgb = lamp colour, w = intensity (0 turns the camcorder lamp off).
    public var flash = SIMD4<Float>(1.0, 0.95, 0.85, 0)
    /// cosInner, cosOuter, range, exposure.
    public var flashParams = SIMD4<Float>(0.94, 0.80, 26, 1.05)
    /// x = active point-light count.
    public var misc = SIMD4<Float>(0, 0, 0, 0)
    /// Fixed-size tail; MSL cannot take a variable-length array in a constant
    /// buffer, so unused slots stay zeroed and `misc.x` bounds the loop.
    public var pointLights = [PointLightUniform](repeating: .zero, count: SceneUniforms.maxPointLights)

    public init() {}

    /// Byte size of the packed buffer handed to Metal: the fixed head plus the
    /// light array. Computed rather than `MemoryLayout<Self>.stride` because
    /// the Swift struct holds an `Array` (a pointer), not inline storage.
    public static var bufferLength: Int {
        MemoryLayout<matrix_float4x4>.size                     // viewProjection
            + MemoryLayout<SIMD4<Float>>.size * 9              // the nine float4s
            + MemoryLayout<SIMD4<Float>>.size * 2 * maxPointLights
    }

    /// Flattens into the contiguous layout `Shaders.metal` expects.
    public func packed() -> [Float] {
        var out = [Float]()
        out.reserveCapacity(SceneUniforms.bufferLength / 4)
        // matrix_float4x4 is four columns, column-major — same as MSL.
        for c in 0..<4 {
            let col = viewProjection[c]
            out.append(contentsOf: [col.x, col.y, col.z, col.w])
        }
        for v in [cameraPos, cameraForward, ambient, hemiSky, hemiGround,
                  fogColor, flash, flashParams, misc] {
            out.append(contentsOf: [v.x, v.y, v.z, v.w])
        }
        for i in 0..<SceneUniforms.maxPointLights {
            let l = i < pointLights.count ? pointLights[i] : .zero
            out.append(contentsOf: [l.positionRange.x, l.positionRange.y,
                                    l.positionRange.z, l.positionRange.w])
            out.append(contentsOf: [l.colorIntensity.x, l.colorIntensity.y,
                                    l.colorIntensity.z, l.colorIntensity.w])
        }
        return out
    }

    /// Convert a `BackroomsCore.Mat4` (column-major, Three.js layout) into the
    /// simd type Metal wants. The layouts already agree, so this is a copy.
    public static func matrix(from mat: Mat4) -> matrix_float4x4 {
        matrix_float4x4(columns: (
            SIMD4<Float>(mat.m[0],  mat.m[1],  mat.m[2],  mat.m[3]),
            SIMD4<Float>(mat.m[4],  mat.m[5],  mat.m[6],  mat.m[7]),
            SIMD4<Float>(mat.m[8],  mat.m[9],  mat.m[10], mat.m[11]),
            SIMD4<Float>(mat.m[12], mat.m[13], mat.m[14], mat.m[15])
        ))
    }

    /// Point the uniforms at a camera pose.
    public mutating func apply(camera: Camera) {
        viewProjection = SceneUniforms.matrix(from: camera.viewProjection)
        cameraPos = SIMD4(camera.x, camera.y, camera.z, 0)
        let f = camera.forward
        cameraForward = SIMD4(f.x, f.y, f.z, 0)
    }

    /// Load the nearest ceiling fixtures, exactly as the web renderer does with
    /// its pool of eight point lights.
    public mutating func loadNearestLights(from map: GameMap,
                                           playerX: Double, playerZ: Double,
                                           lightY: Float, color: SIMD3<Float>,
                                           intensity: Float, range: Float) {
        let ranked = map.fixtures
            .map { f -> (Double, GameMap.Fixture) in
                let dx = map.cellWorldX(f.cellX) - playerX
                let dz = map.cellWorldZ(f.cellZ) - playerZ
                return (dx * dx + dz * dz, f)
            }
            .sorted { $0.0 < $1.0 }
            .prefix(SceneUniforms.maxPointLights)

        pointLights = [PointLightUniform](repeating: .zero, count: SceneUniforms.maxPointLights)
        for (i, entry) in ranked.enumerated() {
            let f = entry.1
            // A dead fixture still exists in the world; it just does not light.
            pointLights[i] = PointLightUniform(
                x: Float(map.cellWorldX(f.cellX)), y: lightY,
                z: Float(map.cellWorldZ(f.cellZ)), range: range,
                color: color, intensity: intensity)
        }
        misc.x = Float(ranked.count)
    }
}
