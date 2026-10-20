#if canImport(Metal)
import Foundation
import simd
import BackroomsCore

/// The per-floor look, authored.
///
/// Up to now each floor's colour has fallen out of whatever its lights happen
/// to be — which is how a renderer looks when nobody has decided anything.
/// This is the decision. A grade is the cheapest art direction there is: it
/// costs four multiplies in the composite and it is the difference between
/// four rooms lit differently and four places that feel different.
///
/// Values are deliberately restrained. A grade you can *see* as a grade has
/// gone too far; these are meant to be invisible until you put two floors side
/// by side.
public struct GradeUniforms: Equatable {

    /// rgb = per-channel gain, w = saturation (1 = untouched, 0 = greyscale).
    public var tint = SIMD4<Float>(1, 1, 1, 1)
    /// x = contrast about mid-grey, y = black lift, zw spare.
    public var curve = SIMD4<Float>(1, 0, 0, 0)

    public init() {}

    public init(tint: SIMD3<Float>, saturation: Float,
                contrast: Float, lift: Float) {
        self.tint = SIMD4(tint.x, tint.y, tint.z, saturation)
        self.curve = SIMD4(contrast, lift, 0, 0)
    }

    /// Does nothing. What the renderer uses when no grade is supplied, so the
    /// composite has one code path instead of a branch.
    public static let neutral = GradeUniforms()

    public static let floatCount = 8

    public func packed() -> [Float] {
        [tint.x, tint.y, tint.z, tint.w,
         curve.x, curve.y, curve.z, curve.w]
    }

    /// The four floors.
    public static func forTheme(_ theme: LevelSpec.Theme) -> GradeUniforms {
        switch theme {
        case .lobby:
            // Nicotine. Push yellow, pull a little blue out of the shadows,
            // and hold contrast near normal — the Lobby's horror is that it
            // looks like somewhere you have actually been.
            return GradeUniforms(tint: SIMD3(1.055, 1.005, 0.880),
                                 saturation: 0.92, contrast: 1.06, lift: 0.006)
        case .warehouse:
            // Cold, hard and emptied out. The highest contrast of the four,
            // because this floor is about what the light does not reach.
            return GradeUniforms(tint: SIMD3(0.925, 0.980, 1.095),
                                 saturation: 0.84, contrast: 1.13, lift: 0.0)
        case .pipes:
            // Hot and close. Crushed blacks so the corridors feel tighter
            // than they measure.
            return GradeUniforms(tint: SIMD3(1.120, 0.940, 0.800),
                                 saturation: 0.97, contrast: 1.15, lift: 0.0)
        case .pool:
            // Bleached and over-lit, with the blacks lifted off the floor so
            // nothing in the room is ever properly dark. The tile should read
            // as milky rather than white, and the whole floor should feel
            // like it is one stop too bright.
            return GradeUniforms(tint: SIMD3(0.945, 1.035, 1.020),
                                 saturation: 0.90, contrast: 0.95, lift: 0.028)
        }
    }
}
#endif
