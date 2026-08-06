import Foundation

/// One material's three maps, as raw pixel buffers ready for GPU upload.
///
/// Kept in `BackroomsCore` rather than the renderer on purpose: texture
/// synthesis is deterministic arithmetic with no GPU in it, so it stays
/// unit-testable on any machine, exactly like the map generator.
public struct SurfaceTextures: Sendable {
    public let size: Int
    /// RGBA8, sRGB.
    public let albedo: [UInt8]
    /// RGBA8, linear — tangent-space normals.
    public let normal: [UInt8]
    /// R8, linear — 0 = mirror, 255 = fully rough.
    public let roughness: [UInt8]

    public init(size: Int, albedo: [UInt8], normal: [UInt8], roughness: [UInt8]) {
        self.size = size
        self.albedo = albedo
        self.normal = normal
        self.roughness = roughness
    }
}

/// The three surfaces a floor is built from, plus how often they repeat.
public struct ThemeTextures: Sendable {
    public let wall: SurfaceTextures
    public let floor: SurfaceTextures
    public let ceiling: SurfaceTextures
    /// Metres covered by one repeat of the floor / ceiling sheet.
    public let floorTile: Double
    public let ceilingTile: Double
    /// Multiplied into the floor albedo — the Poolrooms tint their floor tile
    /// cooler than the wall tile even though both come from one generator.
    public let floorTintR: Double
    public let floorTintG: Double
    public let floorTintB: Double

    public var floorIsTinted: Bool { floorTintR != 1 || floorTintG != 1 || floorTintB != 1 }
}

/// Ports of the web build's `gen*` texture functions.
///
/// The per-pixel material loops are transcribed line for line, including the
/// magic constants — they are the look. The Canvas2D grime passes on top are
/// reimplemented against `TextureCanvas` (see the note there).
public enum ProceduralTextures {

    /// Metres per repeat of the floor and ceiling sheets. Split out from
    /// `forTheme` because a caller that has already cached its textures still
    /// needs these to build the ground planes, and should not pay a second of
    /// CPU to look up two constants.
    public static func tileScales(_ theme: LevelSpec.Theme) -> (floor: Double, ceiling: Double) {
        switch theme {
        case .lobby:     return (2.4, 1.2)
        case .warehouse: return (4.0, 3.0)
        case .pipes:     return (3.0, 3.0)
        case .pool:      return (1.5, 1.2)
        }
    }

    public static func forTheme(_ theme: LevelSpec.Theme) -> ThemeTextures {
        switch theme {
        case .lobby:
            return ThemeTextures(wall: wallpaper(), floor: carpet(), ceiling: lobbyCeiling(),
                                 floorTile: tileScales(theme).floor,
                                 ceilingTile: tileScales(theme).ceiling,
                                 floorTintR: 1, floorTintG: 1, floorTintB: 1)
        case .warehouse:
            return ThemeTextures(wall: concreteWall(), floor: concreteFloor(),
                                 ceiling: warehouseCeiling(),
                                 floorTile: tileScales(theme).floor,
                                 ceilingTile: tileScales(theme).ceiling,
                                 floorTintR: 1, floorTintG: 1, floorTintB: 1)
        case .pipes:
            // The tunnels use the wall sheet overhead too — there is no
            // separate ceiling material in the web build either.
            let wall = tunnelWall()
            return ThemeTextures(wall: wall, floor: tunnelFloor(), ceiling: wall,
                                 floorTile: tileScales(theme).floor,
                                 ceilingTile: tileScales(theme).ceiling,
                                 floorTintR: 1, floorTintG: 1, floorTintB: 1)
        case .pool:
            let tile = poolTile()
            // 0x93a2a4 — the floor tile reads colder under the water.
            return ThemeTextures(wall: tile, floor: tile, ceiling: poolCeiling(),
                                 floorTile: tileScales(theme).floor,
                                 ceilingTile: tileScales(theme).ceiling,
                                 floorTintR: 0x93 / 255.0,
                                 floorTintG: 0xa2 / 255.0,
                                 floorTintB: 0xa4 / 255.0)
        }
    }

    // MARK: - Level 0: yellow wallpaper, damp carpet, drop ceiling

    public static func wallpaper() -> SurfaceTextures {
        let S = 512                      // half the web build's 1024; see note below
        var c = TextureCanvas(size: S)
        let nG = ValueNoise(seed: 101, period: 256)
        let nM = ValueNoise(seed: 102, period: 64)
        let nMot = ValueNoise(seed: 103, period: 8)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)
        let BB = 22                      // baseboard height, scaled with S
        let stripeW = S / 16, seamW = S / 8

        for y in 0..<S {
            for x in 0..<S {
                let u = Double(x) / Double(S), v = Double(y) / Double(S)
                var stripe = (x / stripeW) % 2 == 1 ? 3.5 : -3.5
                if x % seamW < 2 { stripe -= 8 }
                let grain = (nG.fbm(u * 256, v * 256, 2) - 0.5) * 11
                          + (nM.fbm(u * 64, v * 64, 2) - 0.5) * 9
                let mot = (nMot.fbm(u * 8, v * 8, 3) - 0.5) * 30
                var r = 204 + stripe + grain + mot
                var g = 181 + stripe + grain * 0.92 + mot * 0.95
                var b = 109 + stripe * 0.8 + grain * 0.6 + mot * 0.68
                var h = 128 + stripe * 1.4 + grain * 2.4 + mot * 0.4
                var rough = 228.0
                if y < 7 { let k = 1 - Double(y) / 7; r -= k * 28; g -= k * 25; b -= k * 16 }
                let bb0 = S - BB
                if y >= bb0 {
                    let t = Double(y - bb0) / Double(BB)
                    r = 82 - 20 * t + grain * 0.5
                    g = 66 - 16 * t + grain * 0.45
                    b = 44 - 11 * t + grain * 0.35
                    rough = 195; h = 145 - 34 * t
                    if y >= S - 2 { r -= 14; g -= 12; b -= 8 }
                } else if y > bb0 - 6 {
                    let k = Double(y - (bb0 - 6)) / 6
                    r -= k * 22; g -= k * 19; b -= k * 12
                }
                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = TextureCanvas.clamp8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        var sr = Mulberry32(seed: 777)
        for _ in 0..<24 {
            let top = sr.nextUnit() < 0.32
            let sx = sr.nextUnit() * Double(S)
            let sy = top ? sr.nextUnit() * Double(S) * 0.14
                         : Double(S - BB) - 5 - sr.nextUnit() * Double(S) * 0.28
            c.stain(x: sx, y: sy, radius: 9 + sr.nextUnit() * 36,
                    aspect: 0.5 + sr.nextUnit() * 0.7, rotation: sr.nextUnit() * 3.14,
                    r: 82, g: 62, b: 28, alpha: 0.14)
        }
        for _ in 0..<7 {
            c.drip(x: (sr.nextUnit() * Double(S)).rounded(.down), top: 4,
                   length: 30 + sr.nextUnit() * 120, width: 1 + sr.nextUnit() * 2,
                   r: 70, g: 54, b: 24, alpha: 0.20)
        }
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.0),
                               roughness: rmap)
    }

    public static func carpet() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let nF = ValueNoise(seed: 201, period: 256)
        let nP = ValueNoise(seed: 202, period: 8)
        let nS = ValueNoise(seed: 203, period: 32)
        var r0 = Mulberry32(seed: 204)
        var hmap = [Float](repeating: 0, count: S * S)

        for y in 0..<S {
            for x in 0..<S {
                let u = Double(x) / Double(S), v = Double(y) / Double(S)
                let f = nF.fbm(u * 256, v * 256, 2)
                let patch = nP.fbm(u * 8, v * 8, 3)
                let streak = (nS(u * 32, v * 6) - 0.5) * 7
                let speck = (r0.nextUnit() - 0.5) * 14
                let m = 0.86 + patch * 0.24
                hmap[y * S + x] = Float(120 + f * 28 + speck * 0.8)
                c.set(x, y,
                      r: (132 + f * 34 + speck + streak) * m,
                      g: (117 + f * 30 + speck * 0.9 + streak) * m,
                      b: (72 + f * 22 + speck * 0.6 + streak * 0.7) * m)
            }
        }
        var sr = Mulberry32(seed: 205)
        for _ in 0..<14 {
            c.stain(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                    radius: 20 + sr.nextUnit() * 60, aspect: 0.6 + sr.nextUnit() * 0.6,
                    rotation: sr.nextUnit() * 3.14, r: 50, g: 40, b: 18, alpha: 0.20)
        }
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.7),
                               roughness: [UInt8](repeating: 245, count: S * S))
    }

    public static func lobbyCeiling() -> SurfaceTextures {
        let S = 512, TILE = 256
        var c = TextureCanvas(size: S)
        var r0 = Mulberry32(seed: 301)
        let nD = ValueNoise(seed: 302, period: 256)
        var tint = [Double]()
        for _ in 0..<4 { tint.append((r0.nextUnit() - 0.5) * 12) }
        var hmap = [Float](repeating: 0, count: S * S)

        for y in 0..<S {
            for x in 0..<S {
                let gx = x % TILE, gy = y % TILE
                let ti = (x / TILE) + (y / TILE) * 2
                var r: Double, g: Double, b: Double, h: Double
                if gx < 4 || gy < 4 {
                    r = 58; g = 56; b = 50; h = 70
                } else {
                    let dot = nD(Double(x) * 0.9, Double(y) * 0.9) > 0.90 ? -20.0 : 0.0
                    let fn = (nD(Double(x) * 0.18, Double(y) * 0.18) - 0.5) * 10
                    r = 213 + tint[ti] + fn + dot
                    g = 207 + tint[ti] + fn + dot
                    b = 188 + tint[ti] * 0.8 + fn + dot
                    h = 128 + fn * 0.8 + dot * 0.4
                    if gx < 8 || gy < 8 { r -= 12; g -= 12; b -= 10; h -= 8 }
                }
                hmap[y * S + x] = Float(h)
                c.set(x, y, r: r, g: g, b: b)
            }
        }
        // Water damage: concentric rings with a soft blot in the middle. It is
        // the single most recognisable Backrooms ceiling detail.
        var sr = Mulberry32(seed: 303)
        for _ in 0..<5 {
            let cx = 64 + Double(Int(sr.nextUnit() * 2) * TILE) + sr.nextUnit() * 128
            let cy = 64 + Double(Int(sr.nextUnit() * 2) * TILE) + sr.nextUnit() * 128
            for k in 0..<3 {
                c.ring(x: cx, y: cy, radius: 18 + Double(k) * 14 + sr.nextUnit() * 8,
                       width: 3 + Double(k) * 2,
                       r: 120, g: 92, b: 44, alpha: 0.18 - Double(k) * 0.05)
            }
            c.stain(x: cx, y: cy, radius: 30, aspect: 1, rotation: 0,
                    r: 120, g: 92, b: 44, alpha: 0.10)
        }
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 0.9),
                               roughness: [UInt8](repeating: 235, count: S * S))
    }

    // MARK: - Level 1: poured concrete, seams, rust, puddles

    public static func concreteWall() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let nB = ValueNoise(seed: 401, period: 8)
        let nF = ValueNoise(seed: 402, period: 128)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            for x in 0..<S {
                let u = Double(x) / Double(S), v = Double(y) / Double(S)
                let mot = (nB.fbm(u * 8, v * 8, 3) - 0.5) * 26
                let fn = (nF.fbm(u * 128, v * 128, 2) - 0.5) * 12
                var g0 = 118 + mot + fn
                var h = 128 + fn * 1.6 + mot * 0.5
                var rough = 205.0
                if x % 128 < 3 || (x + 64) % 256 < 2 { g0 -= 26; h -= 22 }   // form seams
                if y > 252 && y < 256 { g0 -= 20; h -= 14 }                  // pour line
                if y < 18 { g0 -= (1 - Double(y) / 18) * 22 }                // top shade
                if y > S - 56 {
                    g0 -= (Double(y - (S - 56)) / 56) * 30                   // bottom grime
                    rough = 230
                }
                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = TextureCanvas.clamp8(rough)
                c.set(x, y, r: g0 * 0.96, g: g0, b: g0 * 1.04)
            }
        }
        var sr = Mulberry32(seed: 403)
        for _ in 0..<8 {
            c.drip(x: (sr.nextUnit() * Double(S)).rounded(.down),
                   top: 4 + sr.nextUnit() * 40,
                   length: 80 + sr.nextUnit() * 260, width: 2 + sr.nextUnit() * 4,
                   r: 122, g: 66, b: 30, alpha: 0.30)
        }
        for _ in 0..<10 {
            c.stain(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                    radius: 16 + sr.nextUnit() * 60, aspect: 0.5 + sr.nextUnit() * 0.8,
                    rotation: sr.nextUnit() * 3.14, r: 30, g: 32, b: 34, alpha: 0.16)
        }
        c.cracks(count: 4, seed: 404, r: 28, g: 30, b: 32, alpha: 0.35, maxWidth: 1.2)
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.2),
                               roughness: rmap)
    }

    public static func concreteFloor() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let nB = ValueNoise(seed: 411, period: 8)
        let nF = ValueNoise(seed: 412, period: 128)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)
        var sr0 = Mulberry32(seed: 414)
        var puddles: [(x: Double, y: Double, r: Double)] = []
        for _ in 0..<4 {
            puddles.append((sr0.nextUnit() * Double(S), sr0.nextUnit() * Double(S),
                            30 + sr0.nextUnit() * 55))
        }

        for y in 0..<S {
            for x in 0..<S {
                let u = Double(x) / Double(S), v = Double(y) / Double(S)
                let mot = (nB.fbm(u * 8, v * 8, 3) - 0.5) * 22
                let fn = (nF.fbm(u * 128, v * 128, 2) - 0.5) * 10
                var g0 = 138 + mot + fn
                var h = 128 + fn * 1.4
                var rough = 232.0
                if x < 3 || y < 3 { g0 -= 34; h -= 20 }        // expansion joints
                for p in puddles {
                    // Wrapped distance: puddles must survive the tile seam.
                    let ax = abs(Double(x) - p.x), ay = abs(Double(y) - p.y)
                    let dx = min(ax, Double(S) - ax), dy = min(ay, Double(S) - ay)
                    let dd = (dx * dx + dy * dy).squareRoot()
                    if dd < p.r {
                        let k = 1 - dd / p.r
                        g0 -= k * 26
                        rough = min(rough, 232 - k * 180)      // standing water is glossy
                        h -= k * 2
                    }
                }
                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = TextureCanvas.clamp8(rough)
                c.set(x, y, r: g0 * 0.97, g: g0, b: g0 * 1.03)
            }
        }
        var sr = Mulberry32(seed: 413)
        for _ in 0..<7 {
            c.stain(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                    radius: 18 + sr.nextUnit() * 50, aspect: 0.6 + sr.nextUnit() * 0.6,
                    rotation: sr.nextUnit() * 3.14, r: 18, g: 18, b: 20, alpha: 0.22)
        }
        c.cracks(count: 6, seed: 415, r: 40, g: 42, b: 44, alpha: 0.40, maxWidth: 1.4)
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.0),
                               roughness: rmap)
    }

    public static func warehouseCeiling() -> SurfaceTextures {
        let S = 256
        var c = TextureCanvas(size: S)
        let nB = ValueNoise(seed: 421, period: 8)
        var hmap = [Float](repeating: 0, count: S * S)
        for y in 0..<S {
            for x in 0..<S {
                let mot = (nB.fbm(Double(x) / Double(S) * 8, Double(y) / Double(S) * 8, 3) - 0.5) * 16
                var g0 = 58 + mot
                var h = 128.0
                if y % 128 < 10 { g0 -= 16; h -= 18 }          // beam shadow stripes
                hmap[y * S + x] = Float(h + mot * 0.6)
                c.set(x, y, r: g0 * 0.95, g: g0, b: g0 * 1.06)
            }
        }
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 0.8),
                               roughness: [UInt8](repeating: 225, count: S * S))
    }

    // MARK: - Level 2: soot, mould, faded paint

    public static func tunnelWall() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let nB = ValueNoise(seed: 501, period: 8)
        let nF = ValueNoise(seed: 502, period: 128)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            for x in 0..<S {
                let u = Double(x) / Double(S), v = Double(y) / Double(S)
                let mot = (nB.fbm(u * 8, v * 8, 3) - 0.5) * 30
                let fn = (nF.fbm(u * 128, v * 128, 2) - 0.5) * 12
                let g0 = 86 + mot + fn
                var rough = 212.0
                var r = g0 * 1.06, g = g0 * 0.96, b = g0 * 0.82   // warm grime
                if y < 70 { let k = 1 - Double(y) / 70; r -= k * 30; g -= k * 28; b -= k * 22 }
                if y > S - 50 {
                    let k = Double(y - (S - 50)) / 50
                    r -= k * 26; g -= k * 24; b -= k * 18
                    rough = 235
                }
                hmap[y * S + x] = Float(128 + fn * 1.6)
                rmap[y * S + x] = TextureCanvas.clamp8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }
        var sr = Mulberry32(seed: 503)
        for _ in 0..<10 {
            c.stain(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                    radius: 16 + sr.nextUnit() * 54, aspect: 0.5 + sr.nextUnit() * 0.9,
                    rotation: sr.nextUnit() * 3.14, r: 20, g: 16, b: 12, alpha: 0.22)
        }
        for _ in 0..<6 {   // mould, which only grows down where the damp is
            c.stain(x: sr.nextUnit() * Double(S),
                    y: Double(S) * 0.3 + sr.nextUnit() * Double(S) * 0.6,
                    radius: 12 + sr.nextUnit() * 30, aspect: 0.7, rotation: 0,
                    r: 62, g: 76, b: 48, alpha: 0.20)
        }
        c.cracks(count: 5, seed: 504, r: 16, g: 12, b: 8, alpha: 0.40, maxWidth: 1.3)
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.3),
                               roughness: rmap)
    }

    public static func tunnelFloor() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let nB = ValueNoise(seed: 511, period: 8)
        let nF = ValueNoise(seed: 512, period: 128)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            for x in 0..<S {
                let u = Double(x) / Double(S), v = Double(y) / Double(S)
                let mot = nB.fbm(u * 8, v * 8, 3)
                let fn = (nF.fbm(u * 128, v * 128, 2) - 0.5) * 10
                let worn = mot > 0.62                       // paint walked off
                var r: Double, g: Double, b: Double
                var rough = 205.0
                if worn {
                    let g0 = 104 + fn
                    r = g0 * 1.02; g = g0; b = g0 * 0.92
                    rough = 228
                } else {
                    let g0 = 86 + fn + (mot - 0.5) * 14     // faded blue paint
                    r = g0 * 0.82; g = g0 * 0.95; b = g0 * 1.18
                }
                var h = 128 + fn * 1.2 - (worn ? 6 : 0)
                if x < 3 || y < 3 { r -= 26; g -= 26; b -= 26; h -= 16 }
                if mot < 0.22 {                             // wet sheen in the low spots
                    let k = (0.22 - mot) / 0.22
                    rough -= k * 130; r -= k * 14; g -= k * 12; b -= k * 8
                }
                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = TextureCanvas.clamp8(max(40, rough))
                c.set(x, y, r: r, g: g, b: b)
            }
        }
        var sr = Mulberry32(seed: 513)
        for _ in 0..<8 {
            c.stain(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                    radius: 14 + sr.nextUnit() * 44, aspect: 0.6,
                    rotation: sr.nextUnit() * 3.14, r: 14, g: 12, b: 10, alpha: 0.24)
        }
        c.cracks(count: 5, seed: 514, r: 20, g: 18, b: 14, alpha: 0.40, maxWidth: 1.2)
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.0),
                               roughness: rmap)
    }

    // MARK: - Level 37: Poolrooms

    public static func poolTile() -> SurfaceTextures {
        let S = 512, TILE = 128
        var c = TextureCanvas(size: S)
        let nF = ValueNoise(seed: 701, period: 64)
        var r0 = Mulberry32(seed: 702)
        var tint = [Double]()
        for _ in 0..<16 { tint.append((r0.nextUnit() - 0.5) * 8) }
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            for x in 0..<S {
                let gx = x % TILE, gy = y % TILE
                let ti = (x / TILE) + (y / TILE) * 4
                var g0: Double, h: Double, rough: Double
                if gx < 6 || gy < 6 {
                    g0 = 148; h = 58; rough = 215            // grout
                } else {
                    // Each tile bulges slightly, which is what catches the light
                    // and makes a wall of them read as ceramic.
                    let u = Double(gx - 6) / Double(TILE - 6)
                    let v = Double(gy - 6) / Double(TILE - 6)
                    let dome = sin(u * .pi) * sin(v * .pi)
                    let fn = (nF.fbm(Double(x) / Double(S) * 64, Double(y) / Double(S) * 64, 2) - 0.5) * 7
                    g0 = 228 + tint[ti] + fn + dome * 7
                    h = 120 + dome * 46 + fn
                    rough = 70 + (1 - dome) * 60 + fn * 3
                }
                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = TextureCanvas.clamp8(rough)
                c.set(x, y, r: g0, g: g0 * 0.995, b: g0 * 0.975)
            }
        }
        var sr = Mulberry32(seed: 703)
        for _ in 0..<6 {
            c.stain(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                    radius: 14 + sr.nextUnit() * 30, aspect: 0.7,
                    rotation: sr.nextUnit() * 3.14, r: 120, g: 130, b: 130, alpha: 0.07)
        }
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.5),
                               roughness: rmap)
    }

    public static func poolCeiling() -> SurfaceTextures {
        let S = 256, TILE = 16
        var c = TextureCanvas(size: S)
        var r0 = Mulberry32(seed: 711)
        var tint = [Double](repeating: 0, count: 256)
        for i in 0..<256 { tint[i] = (r0.nextUnit() - 0.5) * 16 }
        var hmap = [Float](repeating: 0, count: S * S)
        for y in 0..<S {
            for x in 0..<S {
                let gx = x % TILE, gy = y % TILE
                let ti = (x / TILE) + (y / TILE) * 16
                let g0: Double, h: Double
                if gx < 2 || gy < 2 { g0 = 92; h = 80 }
                else { g0 = 152 + tint[ti]; h = 128 }
                hmap[y * S + x] = Float(h)
                c.set(x, y, r: g0, g: g0, b: g0 * 1.03)
            }
        }
        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 0.8),
                               roughness: [UInt8](repeating: 170, count: S * S))
    }
}
