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

/// Synthesis of every wall, floor and ceiling material in the game.
///
/// These began as ports of the web build's `gen*` functions, which were written
/// against a Blinn-Phong shader where roughness was one number feeding a
/// specular exponent. The renderer now runs Cook-Torrance GGX, where roughness
/// sets the lobe's shape, width *and* energy, and a flat or arbitrary roughness
/// channel is immediately obvious — a wall reads as plastic, a puddle reads as
/// grey paint. So the roughness maps here are authored against measured
/// reference ranges rather than eyeballed, and quoted in perceptual 0…1 (what
/// the shader samples and squares) at every site:
///
///   glazed ceramic 0.05–0.25   cementitious grout 0.60–0.90
///   painted drywall 0.60–0.75  aged/raw concrete 0.70–0.90
///   sealed concrete 0.55–0.70  textile/carpet 0.88–0.98
///   semi-gloss enamel 0.35–0.50  standing water 0.05–0.12
///
/// Three other things changed with the lighting model:
///
/// * **Height is in texel units.** A difference of 1.0 between neighbouring
///   texels is a 45° facet at `strength` 1 (see `normalMap`). The old fields
///   mixed colour-scale numbers into the height, so feature edges saturated the
///   normal sideways — a hard rim that mips into a dark line rather than a
///   bevel that catches a highlight.
/// * **Grime is not a decal.** Every overlay pass hands back a coverage mask
///   (`TextureCanvas.takeWear`) which is folded into roughness and height with
///   the polarity that particular grime has: a scuff polishes, a mineral crust
///   dulls, a crack sinks.
/// * **Broadband detail.** `FractalNoise` gives each octave its own lattice, so
///   surfaces carry structure from two cycles per repeat down to the texel
///   instead of one or two dominant frequencies. Under a moving flashlight
///   that difference is the whole game: single-frequency noise strobes, a 1/f
///   spectrum reads as material.
public enum ProceduralTextures {

    // MARK: - Shared helpers

    @inline(__always)
    private static func clamp01(_ x: Double) -> Double {
        if x < 0 { return 0 }
        if x > 1 { return 1 }
        return x
    }

    @inline(__always)
    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        if e1 <= e0 { return x < e0 ? 0 : 1 }
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        return a + (b - a) * t
    }

    /// Perceptual roughness (0 = mirror, 1 = fully rough) to the R8 the shader
    /// samples. Every roughness in this file is written in the 0…1 form so it
    /// can be read straight off a reference chart; this is the only place the
    /// byte encoding appears.
    @inline(__always)
    private static func rough8(_ r: Double) -> UInt8 {
        return TextureCanvas.clamp8(clamp01(r) * 255)
    }

    /// Folds overlay coverage into the roughness map. `delta` is in perceptual
    /// roughness at full coverage, so +0.12 means "this grime, where it is
    /// opaque, is 0.12 rougher than what it landed on".
    private static func foldWear(_ mask: [Float], intoRoughness rough: inout [UInt8],
                                 delta: Double) {
        guard mask.count == rough.count else { return }
        let step = delta * 255
        for i in 0..<rough.count {
            let m = Double(mask[i])
            if m <= 0 { continue }
            rough[i] = TextureCanvas.clamp8(Double(rough[i]) + m * step)
        }
    }

    /// Folds overlay coverage into the height field, in texel units.
    private static func foldWear(_ mask: [Float], intoHeight heights: inout [Float],
                                 delta: Double) {
        guard mask.count == heights.count else { return }
        for i in 0..<heights.count {
            let m = Double(mask[i])
            if m <= 0 { continue }
            heights[i] = Float(Double(heights[i]) + m * delta)
        }
    }

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

    /// Aged vinyl wallpaper over drywall, with a painted timber baseboard.
    ///
    /// 512² over a 3.0 m horizontal repeat and the full 3.2 m wall height, so
    /// roughly 6 mm to a texel on both axes. Only the horizontal axis repeats —
    /// the vertical one runs floor to ceiling exactly once — which is why all
    /// the storytelling (grime rising off the carpet, the ceiling shadow, the
    /// baseboard) is stacked vertically where it can never tile.
    public static func wallpaper() -> SurfaceTextures {
        let S = 512
        let BB = 22                       // baseboard, ~14 cm of the 3.2 m wall
        let bb0 = S - BB
        let stripeW = Double(S / 16)      // ~19 cm printed stripe
        let seamW = S / 8                 // ~37 cm between hung strips
        var c = TextureCanvas(size: S)

        // Slow drift, blotchy discolouration, paper tooth. Three lattices
        // spanning 2…256 cycles per repeat: enough spectrum that no single
        // frequency dominates and gives the repeat away.
        let macro = FractalNoise(seed: 101, base: 2, octaves: 3)
        let mid = FractalNoise(seed: 102, base: 16, octaves: 3)
        let fine = FractalNoise(seed: 103, base: 128, octaves: 2)

        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let grain = fine.signed(u, v)
                let blotchRaw = mid(u, v)
                let blotch = blotchRaw * 2 - 1
                let driftRaw = macro(u, v)
                let drift = driftRaw * 2 - 1

                // The stripe is printed ink, not a step: it has a soft edge,
                // and the run wanders because the paper was hung by hand.
                var sp = (Double(x) + drift * 2.0) / stripeW
                sp -= (sp * 0.5).rounded(.down) * 2
                let edgePx = min(sp, min(abs(sp - 1), 2 - sp)) * stripeW
                let ink = smoothstep(0.0, 1.8, edgePx)
                let raised = sp >= 1
                let stripe = (raised ? 3.4 : -3.4) * ink

                // Butt seam between hung strips: a hairline of shadow and the
                // slight ridge where one edge overlaps the next.
                let sd = Double(x % seamW)
                let seam = 1 - smoothstep(0.0, 2.2, min(sd, Double(seamW) - sd))

                var r = 204 + stripe + grain * 5.0 + blotch * 6.5 + drift * 9.0 - seam * 9
                var g = 181 + stripe + grain * 4.6 + blotch * 5.8 + drift * 8.4 - seam * 8
                var b = 109 + stripe * 0.8 + grain * 3.0 + blotch * 3.8 + drift * 6.2 - seam * 6
                // Matte vinyl paper. Reference puts painted drywall at
                // 0.60–0.75; forty years of nicotine and washing put this a
                // little above it, and the embossed stripe holds more dust.
                var rough = 0.78 + grain * 0.030 + blotch * 0.045
                if raised { rough += ink * 0.02 }
                var h = grain * 0.12 + blotch * 0.06 + seam * 0.30
                if raised { h += ink * 0.20 }

                if y < bb0 {
                    // Damp discolours paper and then takes it off the wall.
                    // Driving both from one field is why the bare patches sit
                    // inside the stains instead of beside them.
                    let damp = blotchRaw * 0.75 + driftRaw * 0.25
                    // `lift` is the annulus just outside `bare`, so the paper
                    // curls up at the edge of the hole rather than beside it.
                    let lift = smoothstep(0.60, 0.65, damp) * (1 - smoothstep(0.65, 0.70, damp))
                    let bare = smoothstep(0.66, 0.74, damp)
                    if bare > 0 {
                        // Skim-coat plaster: warm grey, and much rougher than
                        // the vinyl that used to cover it. Kept warm (r > g > b)
                        // on purpose — a neutral grey here would drag the whole
                        // wall off yellow wherever the paper has gone.
                        r = mix(r, 166, bare)
                        g = mix(g, 156, bare)
                        b = mix(b, 140, bare)
                        rough = mix(rough, 0.88, bare)
                        h -= bare * 0.45
                    }
                    if lift > 0 {
                        // The lifted edge is the most legible thing on this
                        // wall under a raking flashlight, so it gets real
                        // height rather than just a darker line.
                        h += lift * 0.9
                        r -= lift * 10
                        g -= lift * 9
                        b -= lift * 6
                    }
                    if y < 10 {
                        let k = 1 - Double(y) / 10
                        r -= k * 26; g -= k * 24; b -= k * 17
                    }
                    // Traffic grime creeping up off the carpet, modulated so it
                    // is a tide line rather than a gradient.
                    let toBase = Double(bb0 - y)
                    let dirt = (1 - smoothstep(0, 50, toBase)) * (0.45 + 0.55 * blotchRaw)
                    r -= dirt * 26; g -= dirt * 24; b -= dirt * 17
                    rough += dirt * 0.06
                } else {
                    // Painted timber baseboard: semi-gloss enamel, 0.46 fresh,
                    // scuffing back toward matte at the floor. Under GGX this
                    // horizontal band of lower roughness is what gives the base
                    // of every wall a readable highlight.
                    let t = Double(y - bb0) / Double(BB)
                    r = (86 - 17 * t) + grain * 3.0
                    g = (68 - 14 * t) + grain * 2.6
                    b = (46 - 10 * t) + grain * 2.0
                    rough = 0.46 + 0.24 * t + grain * 0.02
                    // Chamfer at the top edge, flat face, shadow gap at the
                    // carpet. The gap also heals the vertical wrap: the sheet's
                    // first and last rows both sit at −1.5.
                    let up = Double(y - bb0)
                    let down = Double(S - 1 - y)
                    let stand = smoothstep(0.0, 3.5, up) * smoothstep(0.0, 2.5, down)
                    h = 2.0 * stand - 1.5 * (1 - smoothstep(0.0, 2.5, down)) + grain * 0.08
                }
                if y < 2 { h = -1.5 }

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        // Water off the ceiling and up from the floor. Ragged edges, because a
        // clean ellipse on a wall is the tell that a texture was generated.
        var sr = Mulberry32(seed: 777)
        let edgeNoise = ValueNoise(seed: 778, period: 64)
        for _ in 0..<26 {
            let top = sr.nextUnit() < 0.34
            let sx = sr.nextUnit() * Double(S)
            let sy = top ? sr.nextUnit() * Double(S) * 0.16
                         : Double(bb0) - 6 - sr.nextUnit() * Double(S) * 0.30
            c.blot(x: sx, y: sy, radius: 10 + sr.nextUnit() * 36,
                   aspect: 0.5 + sr.nextUnit() * 0.7, rotation: sr.nextUnit() * 3.14,
                   wobble: 0.5, noise: edgeNoise,
                   r: 86, g: 64, b: 28, alpha: 0.13)
        }
        for i in 0..<9 {
            c.runoff(x: sr.nextUnit() * Double(S), top: 3,
                     length: 40 + sr.nextUnit() * 150, width: 2 + sr.nextUnit() * 3,
                     wander: 4, seed: 790 &+ UInt32(i),
                     r: 72, g: 55, b: 25, alpha: 0.20)
        }
        // Dried water leaves a mineral crust, and paper cockles where it dries.
        let waterWear = c.takeWear()
        foldWear(waterWear, intoRoughness: &rmap, delta: 0.10)
        foldWear(waterWear, intoHeight: &hmap, delta: 0.20)

        // Shoe scuffs along the baseboard, which do the opposite: they burnish
        // the enamel rather than dulling it.
        for _ in 0..<20 {
            let sy = Double(bb0) - 6 + sr.nextUnit() * Double(BB)
            let sx = sr.nextUnit() * Double(S)
            let len = 8 + sr.nextUnit() * 32
            c.smear(x0: sx, y0: sy, x1: sx + len, y1: sy + (sr.nextUnit() - 0.5) * 4,
                    width: 1.5 + sr.nextUnit() * 2.5,
                    r: 52, g: 45, b: 36, alpha: 0.22)
        }
        let scuffWear = c.takeWear()
        foldWear(scuffWear, intoRoughness: &rmap, delta: -0.14)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 2.0),
                               roughness: rmap)
    }

    /// Commercial cut-pile carpet, mustard-brown, damp and walked flat.
    ///
    /// 512² over a 2.4 m repeat — about 4.7 mm to a texel, which is roughly one
    /// tuft, so individual loops are below the sampling limit. What is
    /// modelled instead is what actually reads at eye height: the directional
    /// grain of the pile, the dye-lot drift, and where feet have been.
    public static func carpet() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let macro = FractalNoise(seed: 201, base: 2, octaves: 3)
        let mid = FractalNoise(seed: 202, base: 16, octaves: 3)
        let weave = FractalNoise(seed: 203, base: 32, octaves: 2)
        var fibre = Mulberry32(seed: 204)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            for x in 0..<S {
                let u = Double(x) / Double(S)
                // Pile lies in a direction, so the grain is stretched: features
                // four times narrower across the lay than along it. Two passes
                // crossed gives the woven read without a literal grid.
                let across = weave.stretched(u, v, xRepeat: 4, yRepeat: 1) * 2 - 1
                let along = weave.stretched(u, v, xRepeat: 1, yRepeat: 4) * 2 - 1
                let tuft = across * 0.6 + along * 0.4
                let midRaw = mid(u, v)
                let dye = midRaw * 2 - 1
                let driftRaw = macro(u, v)
                let speck = (fibre.nextUnit() - 0.5) * 13

                // Traffic. `worn` is where the pile has been crushed flat;
                // `soil` peaks on the shoulders of a path, which is where dirt
                // actually collects — the middle of a walked lane gets cleaner,
                // not dirtier.
                let wornRaw = driftRaw * 0.7 + midRaw * 0.3
                let worn = smoothstep(0.52, 0.74, wornRaw)
                let soil = clamp01(worn * (1 - worn) * 4)

                let shade = 0.88 + 0.22 * driftRaw
                var r = (134 + dye * 9 + tuft * 8 + speck) * shade
                var g = (118 + dye * 8 + tuft * 7 + speck * 0.9) * shade
                var b = (73 + dye * 6 + tuft * 5 + speck * 0.6) * shade
                r += worn * 11 - soil * 24
                g += worn * 10 - soil * 21
                b += worn * 7 - soil * 13

                // Textile is about as diffuse as a surface gets. A matted lane
                // has had its fibre tips polished flat and does come back a
                // little, which is the only specular event this floor gets.
                let rough = 0.94 + tuft * 0.02 - worn * 0.10 - soil * 0.02

                // Pile depth: 8 mm of pile is under two texels, and the crushed
                // lanes lose a third of it.
                var h = tuft * 0.30 + speck * 0.022 + dye * 0.07
                h -= worn * 0.34

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        var sr = Mulberry32(seed: 205)
        let edgeNoise = ValueNoise(seed: 206, period: 64)
        for _ in 0..<16 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 18 + sr.nextUnit() * 54, aspect: 0.6 + sr.nextUnit() * 0.6,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.55, noise: edgeNoise,
                   r: 52, g: 41, b: 19, alpha: 0.20)
        }
        // Damp carpet clumps: darker, and the matted fibre picks up a sheen it
        // has nowhere else on this floor.
        let dampWear = c.takeWear()
        foldWear(dampWear, intoRoughness: &rmap, delta: -0.16)
        foldWear(dampWear, intoHeight: &hmap, delta: -0.18)

        // Ground-in grit.
        c.specks(count: 900, seed: 207, minRadius: 0.5, maxRadius: 1.4,
                 r: 42, g: 36, b: 24, alpha: 0.35)
        let gritWear = c.takeWear()
        foldWear(gritWear, intoRoughness: &rmap, delta: 0.04)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 2.6),
                               roughness: rmap)
    }

    /// Mineral-fibre drop-ceiling panels in a dark grid.
    ///
    /// 512² over a 1.2 m repeat, so 2.3 mm to a texel and 256-texel panels —
    /// close enough to a real 600 mm board. Two features do all the work here:
    /// the worm-track fissures and the pinhole punch. Without them a drop
    /// ceiling is painted card, and it is the surface directly above a
    /// flashlight for most of the game.
    public static func lobbyCeiling() -> SurfaceTextures {
        let S = 512, TILE = 256
        var c = TextureCanvas(size: S)
        let fissure = FractalNoise(seed: 302, base: 16, octaves: 3)
        let grain = FractalNoise(seed: 303, base: 64, octaves: 2)
        let macro = FractalNoise(seed: 304, base: 2, octaves: 2)
        var pin = Mulberry32(seed: 305)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            let gy = y % TILE
            let ty = y / TILE
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let gx = x % TILE
                let tx = x / TILE

                // Distance to the nearest grid line, centred on the panel
                // boundary so both sides of a joint match.
                let dj = Double(min(min(gx, TILE - gx), min(gy, TILE - gy)))
                let seam = 1 - smoothstep(3.0, 5.0, dj)
                let face = smoothstep(4.0, 9.0, dj)

                // Per-panel identity. Four panels to a sheet, so if they were
                // identical the 1.2 m repeat would be unmissable overhead;
                // offsetting the fissure lookup per panel makes each board its
                // own piece of stock.
                let tint = (ProceduralHash.unit(tx, ty, 311) - 0.5) * 13
                let ox = ProceduralHash.unit(tx, ty, 312) * 7
                let oy = ProceduralHash.unit(tx, ty, 313) * 7

                let fs = fissure(u + ox, v + oy)
                let vein = 1 - smoothstep(0.0, 0.013, abs(fs - 0.5))
                let fn = grain.signed(u + ox, v + oy)
                let drift = macro.signed(u, v)

                // Panels sag once they have taken water. A 3-texel bow across a
                // 256-texel board is a very shallow slope, which is exactly
                // right: it shows as a soft shading gradient, not a dent.
                let sagRoll = ProceduralHash.unit(tx, ty, 314)
                let sagAmt = sagRoll > 0.62 ? (sagRoll - 0.62) * 2.4 : 0.0
                let pu = Double(gx) / Double(TILE)
                let pv = Double(gy) / Double(TILE)
                let bow = sin(pu * .pi) * sin(pv * .pi)

                var r = 213 + tint + fn * 5.0 + drift * 4.0
                var g = 207 + tint + fn * 5.0 + drift * 4.0
                var b = 188 + tint * 0.8 + fn * 4.6 + drift * 3.6
                // Mineral fibre is one of the roughest surfaces in the game.
                var rough = 0.92 + fn * 0.02
                var h = fn * 0.14 - vein * 0.55 - sagAmt * bow * 3.0

                r -= vein * 24; g -= vein * 24; b -= vein * 22
                rough += vein * 0.04
                // The pinhole punch: one texel is 2.3 mm, which is a pinhole.
                if pin.nextUnit() > 0.988 {
                    r -= 38; g -= 38; b -= 34
                    h -= 0.7
                }
                r -= sagAmt * bow * 9
                g -= sagAmt * bow * 9
                b -= sagAmt * bow * 8

                if seam > 0 {
                    // The exposed tee grid, dark-anodised, and the shadow
                    // reveal either side of it. Painted metal, so this narrow
                    // band is the one glossy thing on the whole ceiling.
                    let grid = 44 + fn * 3
                    r = mix(r, grid, seam)
                    g = mix(g, grid * 0.98, seam)
                    b = mix(b, grid * 0.94, seam)
                    rough = mix(rough, 0.55, seam)
                    h = mix(h, -2.5, seam)
                }
                // Board edges are cut and slightly chamfered.
                let bevel = 1 - face
                if bevel > 0 && seam <= 0 {
                    r -= bevel * 10; g -= bevel * 10; b -= bevel * 9
                    h -= bevel * 0.8
                }

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        // Water damage: the concentric tide lines a slow leak dries into, with
        // a soft blot in the middle. The single most recognisable Backrooms
        // ceiling detail, and the rings are noise-wobbled so they do not read
        // as drawn circles.
        var sr = Mulberry32(seed: 306)
        let edgeNoise = ValueNoise(seed: 307, period: 64)
        for _ in 0..<6 {
            let cx = 40 + Double(Int(sr.nextUnit() * 2) * TILE) + sr.nextUnit() * 170
            let cy = 40 + Double(Int(sr.nextUnit() * 2) * TILE) + sr.nextUnit() * 170
            for k in 0..<3 {
                c.waterRing(x: cx, y: cy, radius: 18 + Double(k) * 15 + sr.nextUnit() * 8,
                            width: 3 + Double(k) * 2, wobble: 0.35, noise: edgeNoise,
                            r: 124, g: 95, b: 46, alpha: 0.16 - Double(k) * 0.04)
            }
            c.blot(x: cx, y: cy, radius: 30 + sr.nextUnit() * 14, aspect: 1, rotation: 0,
                   wobble: 0.4, noise: edgeNoise,
                   r: 124, g: 95, b: 46, alpha: 0.11)
        }
        // Dried mineral deposit, and the board swells where it got wet.
        let waterWear = c.takeWear()
        foldWear(waterWear, intoRoughness: &rmap, delta: 0.05)
        foldWear(waterWear, intoHeight: &hmap, delta: 0.35)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.6),
                               roughness: rmap)
    }

    // MARK: - Level 1: poured concrete, seams, rust, puddles

    /// Board-formed cast-in-place concrete.
    ///
    /// 512² over a 4.0 m horizontal repeat and 4.6 m of wall — about 8 mm to a
    /// texel. The tell of a real pour is not the noise: it is the form
    /// geometry. Panel joints on a metre grid, snap-tie holes on a half-metre
    /// lattice, a lift line where one pour met the next, and efflorescence
    /// wherever damp has carried salt back out of the slab.
    public static func concreteWall() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let macro = FractalNoise(seed: 401, base: 2, octaves: 3)
        let mid = FractalNoise(seed: 402, base: 16, octaves: 3)
        let fine = FractalNoise(seed: 403, base: 128, octaves: 2)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)
        let tieCell = 64

        for y in 0..<S {
            let v = Double(y) / Double(S)
            let ty = y / tieCell
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let tx = x / tieCell
                let grit = fine.signed(u, v)
                let midRaw = mid(u, v)
                let mot = midRaw * 2 - 1
                let driftRaw = macro(u, v)
                let drift = driftRaw * 2 - 1

                // Aged concrete: reference albedo 0.20–0.30 linear, which lands
                // near 130 sRGB. Slightly blue, as cured cement is.
                var tone = 124 + mot * 11 + drift * 13 + grit * 5
                // Reference roughness for raw concrete is 0.70–0.90; this pour
                // is old and chalky, so it sits mid-range and climbs where the
                // surface has weathered.
                var rough = 0.76 + grit * 0.04 + mot * 0.05
                var h = grit * 0.22 + mot * 0.10

                // Form-panel joints on a 1 m grid, plus the offset row of
                // sheet joints between them. Concrete bleeds through a joint,
                // so the line is a shallow ridge with a shadow, not a groove.
                let jx = Double(x % 128)
                let joint = 1 - smoothstep(0.0, 2.5, min(jx, 128 - jx))
                let jx2 = Double((x + 64) % 256)
                let joint2 = (1 - smoothstep(0.0, 1.8, min(jx2, 256 - jx2))) * 0.55
                let seam = max(joint, joint2)
                tone -= seam * 22
                h += seam * 0.5
                rough += seam * 0.05

                // Lift line where the second pour met the first: the aggregate
                // changes and a little grout ran down over the joint.
                let lift = 1 - smoothstep(0.0, 5.0, abs(Double(y) - 254))
                tone -= lift * 16
                h -= lift * 0.6

                // Snap ties on a half-metre lattice, jittered off it so the eye
                // does not lock onto the grid. The jitter is bounded well
                // inside the cell so no hole is ever clipped by a cell edge.
                let hx = Double(tx * tieCell) + 14 + ProceduralHash.unit(tx, ty, 431) * 36
                let hy = Double(ty * tieCell) + 14 + ProceduralHash.unit(tx, ty, 432) * 36
                let ddx = Double(x) + 0.5 - hx
                let ddy = Double(y) + 0.5 - hy
                let dd = (ddx * ddx + ddy * ddy).squareRoot()
                let tie = 1 - smoothstep(2.2, 4.0, dd)
                let tieRim = smoothstep(3.6, 4.4, dd) * (1 - smoothstep(4.4, 5.6, dd))
                tone -= tie * 30
                h -= tie * 2.2
                h += tieRim * 0.35
                rough += tie * 0.08

                // Efflorescence — salt carried out of the slab by rising damp
                // and left as a pale bloom. It is the one thing on a concrete
                // wall that is *lighter* than the wall, and much rougher.
                let dampZone = smoothstep(0.5, 1.0, v)
                let bloom = smoothstep(0.55, 0.72, midRaw * 0.6 + driftRaw * 0.4) * dampZone
                tone += bloom * 26
                rough += bloom * 0.12

                if y < 20 {
                    tone -= (1 - Double(y) / 20) * 22
                }
                if y > S - 70 {
                    // Splash zone: darker, and damp enough to have lost some
                    // of its roughness.
                    let k = smoothstep(0.0, 70.0, Double(y - (S - 70)))
                    tone -= k * 26
                    rough -= k * 0.14
                }

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: tone * 0.96, g: tone, b: tone * 1.04)
            }
        }

        var sr = Mulberry32(seed: 404)
        let edgeNoise = ValueNoise(seed: 405, period: 64)
        // Rust off whatever is bolted through the wall.
        for i in 0..<9 {
            c.runoff(x: sr.nextUnit() * Double(S), top: 4 + sr.nextUnit() * 40,
                     length: 80 + sr.nextUnit() * 250, width: 3 + sr.nextUnit() * 5,
                     wander: 6, seed: 410 &+ UInt32(i),
                     r: 124, g: 68, b: 30, alpha: 0.30)
        }
        let rustWear = c.takeWear()
        // Iron oxide is powdery — it dulls whatever it lands on.
        foldWear(rustWear, intoRoughness: &rmap, delta: 0.10)

        for _ in 0..<12 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 16 + sr.nextUnit() * 58, aspect: 0.5 + sr.nextUnit() * 0.8,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.5, noise: edgeNoise,
                   r: 32, g: 34, b: 36, alpha: 0.15)
        }
        // Bug holes — the air voids a poor vibration leaves against the form.
        c.specks(count: 520, seed: 406, minRadius: 0.6, maxRadius: 2.2,
                 r: 62, g: 64, b: 66, alpha: 0.5)
        let sootWear = c.takeWear()
        foldWear(sootWear, intoRoughness: &rmap, delta: 0.06)
        foldWear(sootWear, intoHeight: &hmap, delta: -0.30)

        c.cracks(count: 5, seed: 407, r: 28, g: 30, b: 32, alpha: 0.35, maxWidth: 1.2)
        let crackWear = c.takeWear()
        foldWear(crackWear, intoHeight: &hmap, delta: -1.1)
        foldWear(crackWear, intoRoughness: &rmap, delta: 0.08)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.7),
                               roughness: rmap)
    }

    /// Power-trowelled slab with standing water.
    ///
    /// 512² over a 4.0 m repeat — 8 mm to a texel. The puddles are the single
    /// most valuable thing in the theme now that the shader is GGX: standing
    /// water at 0.06 roughness against a 0.86 slab is a two-order-of-magnitude
    /// swing in specular width, and it is what makes a torch beam read as a
    /// torch beam rather than a light blob.
    public static func concreteFloor() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let macro = FractalNoise(seed: 411, base: 2, octaves: 3)
        let mid = FractalNoise(seed: 412, base: 16, octaves: 3)
        let fine = FractalNoise(seed: 413, base: 128, octaves: 2)
        let swirl = FractalNoise(seed: 414, base: 8, octaves: 3)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        var puddleRng = Mulberry32(seed: 415)
        var puddles: [(x: Double, y: Double, r: Double)] = []
        for _ in 0..<5 {
            puddles.append((puddleRng.nextUnit() * Double(S),
                            puddleRng.nextUnit() * Double(S),
                            34 + puddleRng.nextUnit() * 58))
        }

        for y in 0..<S {
            let v = Double(y) / Double(S)
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let grit = fine.signed(u, v)
                let mot = mid.signed(u, v)
                let drift = macro.signed(u, v)

                var tone = 140 + mot * 10 + drift * 12 + grit * 5
                // A sealed, power-trowelled slab is smoother than a raw pour —
                // reference 0.55–0.70 sealed against 0.70–0.90 raw — but this
                // one lost its seal decades ago.
                var rough = 0.86 + grit * 0.03 + mot * 0.04
                // The arcs a power trowel leaves. Ridged noise, because the
                // marks are creases, not blobs.
                let arc = swirl.ridged(u, v) - 0.5
                var h = grit * 0.16 + mot * 0.08 + arc * 0.5
                tone += arc * 5

                // Saw-cut control joints on the 4 m slab grid, with the
                // chamfer the blade leaves.
                let djx = Double(min(x, S - x))
                let djy = Double(min(y, S - y))
                let cut = 1 - smoothstep(1.0, 3.5, min(djx, djy))
                tone -= cut * 40
                h -= cut * 2.2
                rough += cut * 0.05

                // Standing water. Wrapped distance, so a puddle survives the
                // tile seam instead of being cut in half by it.
                for p in puddles {
                    let ax = abs(Double(x) - p.x), ay = abs(Double(y) - p.y)
                    let dx = min(ax, Double(S) - ax), dy = min(ay, Double(S) - ay)
                    let dd = (dx * dx + dy * dy).squareRoot()
                    if dd >= p.r { continue }
                    // Three zones, which is how a real puddle dries: open water
                    // in the middle, a damp halo where the concrete is wet but
                    // not covered, and a pale mineral rim where the last edge
                    // evaporated.
                    let water = 1 - smoothstep(p.r * 0.42, p.r * 0.72, dd)
                    let dampK = 1 - smoothstep(p.r * 0.72, p.r, dd)
                    let rim = smoothstep(p.r * 0.80, p.r * 0.92, dd)
                             * (1 - smoothstep(p.r * 0.92, p.r, dd))
                    tone -= dampK * 20 + water * 12
                    tone += rim * 14
                    rough = mix(rough, 0.62, dampK)
                    rough = mix(rough, 0.06, water)
                    rough += rim * 0.06
                    h -= water * 0.35
                }

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: tone * 0.97, g: tone, b: tone * 1.03)
            }
        }

        var sr = Mulberry32(seed: 416)
        let edgeNoise = ValueNoise(seed: 417, period: 64)
        for _ in 0..<9 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 18 + sr.nextUnit() * 48, aspect: 0.6 + sr.nextUnit() * 0.6,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.5, noise: edgeNoise,
                   r: 20, g: 20, b: 22, alpha: 0.20)
        }
        // Drag marks — something heavy was moved across this floor.
        for _ in 0..<10 {
            let sx = sr.nextUnit() * Double(S)
            let sy = sr.nextUnit() * Double(S)
            let ang = sr.nextUnit() * 6.28
            let len = 40 + sr.nextUnit() * 150
            c.smear(x0: sx, y0: sy, x1: sx + cos(ang) * len, y1: sy + sin(ang) * len,
                    width: 2 + sr.nextUnit() * 5,
                    r: 42, g: 40, b: 40, alpha: 0.20)
        }
        let smudgeWear = c.takeWear()
        // Rubber burnished into a slab leaves it smoother, not rougher.
        foldWear(smudgeWear, intoRoughness: &rmap, delta: -0.10)

        c.specks(count: 700, seed: 418, minRadius: 0.5, maxRadius: 1.6,
                 r: 92, g: 92, b: 94, alpha: 0.35)
        let dustWear = c.takeWear()
        foldWear(dustWear, intoRoughness: &rmap, delta: 0.06)

        c.cracks(count: 7, seed: 419, r: 40, g: 42, b: 44, alpha: 0.40, maxWidth: 1.4)
        let crackWear = c.takeWear()
        foldWear(crackWear, intoHeight: &hmap, delta: -1.2)
        foldWear(crackWear, intoRoughness: &rmap, delta: 0.06)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.7),
                               roughness: rmap)
    }

    /// Corrugated steel deck on open-web joists.
    ///
    /// Raised from 256² to 512² over the 3.0 m repeat (6 mm to a texel): the
    /// rib profile is the whole point of this surface and it was mush at the
    /// old density. That costs about 0.75 MB more in the atlas and four times
    /// the loop of the cheapest generator in the file, which is still the
    /// cheapest generator in the file.
    ///
    /// Twenty ribs across 3 m is a 150 mm pitch — B-deck. The exact integer
    /// matters: a fractional rib count would not tile.
    public static func warehouseCeiling() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let mid = FractalNoise(seed: 421, base: 8, octaves: 3)
        let fine = FractalNoise(seed: 422, base: 64, octaves: 2)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let midRaw = mid(u, v)
                let fineRaw = fine(u, v)
                let mot = midRaw * 2 - 1
                let grit = fineRaw * 2 - 1

                // Trapezoidal rib: flat flute, sloped web, flat crest.
                let phase = u * 20.0
                let rp = phase - phase.rounded(.down)
                let rib = smoothstep(0.30, 0.46, rp) - smoothstep(0.80, 0.96, rp)

                // Joists every 128 texels — 75 cm — hanging below the deck, so
                // they are *closer* to the viewer and read as raised height.
                let jy = Double(y % 128)
                let joist = smoothstep(0.0, 2.5, jy) * (1 - smoothstep(7.5, 10.0, jy))

                // Rust wins wherever water has sat in a flute.
                let rustField = midRaw * 0.65 + fineRaw * 0.35
                let rust = smoothstep(0.54, 0.70, rustField) * (1 - rib * 0.6)

                var tone = 60 + mot * 7 + grit * 4
                // Ribs shade themselves: the crest catches what light there is,
                // the flute holds the dirt.
                tone += rib * 9 - (1 - rib) * 5
                tone -= joist * 18
                // Painted steel deck, dirty: 0.62. Rust is powdery and much
                // rougher; this contrast is most of what sells it as metal.
                var rough = 0.62 + grit * 0.04 + (1 - rib) * 0.05
                rough += rust * 0.26
                var h = rib * 6.0 + joist * 3.0 + grit * 0.18 + mot * 0.10
                h -= rust * 0.3

                var r = tone * 0.95, g = tone, b = tone * 1.06
                if rust > 0 {
                    r = mix(r, 96, rust * 0.75)
                    g = mix(g, 58, rust * 0.75)
                    b = mix(b, 34, rust * 0.75)
                }

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        var sr = Mulberry32(seed: 423)
        for i in 0..<10 {
            c.runoff(x: sr.nextUnit() * Double(S), top: sr.nextUnit() * Double(S),
                     length: 30 + sr.nextUnit() * 90, width: 2 + sr.nextUnit() * 3,
                     wander: 3, seed: 430 &+ UInt32(i),
                     r: 104, g: 60, b: 30, alpha: 0.22)
        }
        let rustWear = c.takeWear()
        foldWear(rustWear, intoRoughness: &rmap, delta: 0.18)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.0),
                               roughness: rmap)
    }

    // MARK: - Level 2: soot, mould, faded paint

    /// Parged service-tunnel wall: sooty at the top, mouldy in the middle,
    /// wet at the base. 512² over a 3.0 m repeat and 2.7 m of height.
    ///
    /// The vertical story is the point. A tunnel wall is not uniformly grimy;
    /// it has a soot ceiling, a hand-height rub line, a tide mark where damp
    /// wicks up, and salt bloom above that where the damp stops.
    public static func tunnelWall() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let macro = FractalNoise(seed: 501, base: 2, octaves: 3)
        let mid = FractalNoise(seed: 502, base: 16, octaves: 3)
        let fine = FractalNoise(seed: 503, base: 128, octaves: 2)
        let parge = FractalNoise(seed: 504, base: 32, octaves: 2)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let fineRaw = fine(u, v)
                let grit = fineRaw * 2 - 1
                let midRaw = mid(u, v)
                let mot = midRaw * 2 - 1
                let driftRaw = macro(u, v)
                let drift = driftRaw * 2 - 1
                // Trowelled render: broad curved sweeps, so ridged noise again.
                let trowel = parge.ridged(u, v) - 0.5

                let tone = 92 + mot * 13 + drift * 14 + grit * 5
                var r = tone * 1.06, g = tone * 0.96, b = tone * 0.82  // warm grime
                var rough = 0.74 + grit * 0.04 + mot * 0.04
                var h = grit * 0.26 + mot * 0.12 + trowel * 0.55

                // Soot, which settles from the top down and is the flattest
                // thing on the wall — carbon black kills every highlight.
                let soot = (1 - smoothstep(0.0, 0.30, v)) * (0.55 + 0.45 * midRaw)
                r -= soot * 34; g -= soot * 32; b -= soot * 26
                rough += soot * 0.12

                // Rising damp: the wall darkens toward the floor, and wet
                // render is markedly glossier than dry render.
                let wet = smoothstep(0.72, 1.0, v) * (0.6 + 0.4 * driftRaw)
                r -= wet * 30; g -= wet * 28; b -= wet * 20
                rough -= wet * 0.26

                // Salt bloom right at the top of the damp line, where the water
                // stops and the minerals do not.
                let tide = smoothstep(0.62, 0.70, v) * (1 - smoothstep(0.70, 0.80, v))
                let bloom = tide * smoothstep(0.45, 0.70, midRaw)
                r += bloom * 26; g += bloom * 26; b += bloom * 24
                rough += bloom * 0.14

                // Condensation beading in the lower half: tiny smooth spots,
                // which under a moving torch sparkle rather than shine.
                let bead = smoothstep(0.70, 0.80, fineRaw) * smoothstep(0.45, 0.85, v)
                rough -= bead * 0.34
                h += bead * 0.20

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        var sr = Mulberry32(seed: 505)
        let edgeNoise = ValueNoise(seed: 506, period: 64)
        for _ in 0..<12 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 16 + sr.nextUnit() * 52, aspect: 0.5 + sr.nextUnit() * 0.9,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.55, noise: edgeNoise,
                   r: 22, g: 18, b: 13, alpha: 0.20)
        }
        let sootWear = c.takeWear()
        foldWear(sootWear, intoRoughness: &rmap, delta: 0.12)

        // Mould, which only grows where the damp is and never has a clean
        // edge — it advances in fingers.
        for _ in 0..<8 {
            c.blot(x: sr.nextUnit() * Double(S),
                   y: Double(S) * 0.32 + sr.nextUnit() * Double(S) * 0.6,
                   radius: 12 + sr.nextUnit() * 30, aspect: 0.7 + sr.nextUnit() * 0.4,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.85, noise: edgeNoise,
                   r: 62, g: 76, b: 48, alpha: 0.22)
        }
        let mouldWear = c.takeWear()
        // A mould mat is fuzzy: rougher than the render, and it stands proud.
        foldWear(mouldWear, intoRoughness: &rmap, delta: 0.16)
        foldWear(mouldWear, intoHeight: &hmap, delta: 0.35)

        // Efflorescence running down out of the cracks.
        for i in 0..<6 {
            c.runoff(x: sr.nextUnit() * Double(S),
                     top: Double(S) * 0.3 + sr.nextUnit() * Double(S) * 0.3,
                     length: 30 + sr.nextUnit() * 90, width: 2 + sr.nextUnit() * 3,
                     wander: 3, seed: 520 &+ UInt32(i),
                     r: 176, g: 174, b: 164, alpha: 0.16)
        }
        let saltWear = c.takeWear()
        foldWear(saltWear, intoRoughness: &rmap, delta: 0.14)

        c.cracks(count: 6, seed: 507, r: 16, g: 12, b: 8, alpha: 0.40, maxWidth: 1.3)
        let crackWear = c.takeWear()
        foldWear(crackWear, intoHeight: &hmap, delta: -1.2)
        foldWear(crackWear, intoRoughness: &rmap, delta: 0.06)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.7),
                               roughness: rmap)
    }

    /// Painted concrete tunnel floor, with the paint walked off it.
    ///
    /// 512² over a 3.0 m repeat. Two materials in one sheet: floor enamel,
    /// which is semi-gloss at 0.42, and the bare slab underneath at 0.84. The
    /// boundary between them is where the surface lives, so it is chipped
    /// rather than faded, with a real step at the paint edge.
    public static func tunnelFloor() -> SurfaceTextures {
        let S = 512
        var c = TextureCanvas(size: S)
        let macro = FractalNoise(seed: 511, base: 2, octaves: 3)
        let mid = FractalNoise(seed: 512, base: 16, octaves: 3)
        let fine = FractalNoise(seed: 513, base: 128, octaves: 2)
        let chip = FractalNoise(seed: 514, base: 32, octaves: 3)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let grit = fine.signed(u, v)
                let midRaw = mid(u, v)
                let driftRaw = macro(u, v)

                // Where the paint has gone. The field is deliberately spiky so
                // the boundary is chipped, and the transition is under two
                // texels wide — paint does not fade off, it comes off.
                let wearField = driftRaw * 0.45 + midRaw * 0.35 + chip(u, v) * 0.20
                let bare = smoothstep(0.50, 0.56, wearField)
                let chipEdge = smoothstep(0.48, 0.52, wearField)
                             * (1 - smoothstep(0.52, 0.58, wearField))

                // Faded blue floor enamel.
                let paintTone = 92 + grit * 5 + (midRaw - 0.5) * 14
                let paintR = paintTone * 0.80
                let paintG = paintTone * 0.94
                let paintB = paintTone * 1.20
                // Bare slab under it.
                let slabTone = 112 + grit * 6 + driftRaw * 8
                let slabR = slabTone * 1.02
                let slabG = slabTone
                let slabB = slabTone * 0.93

                var r = mix(paintR, slabR, bare)
                var g = mix(paintG, slabG, bare)
                var b = mix(paintB, slabB, bare)
                // Floor enamel is semi-gloss (0.35–0.50); the slab it exposes
                // is raw and chalky (0.80–0.90).
                var rough = mix(0.42, 0.84, bare) + grit * 0.03
                // The paint film stands about a texel proud of the slab, and
                // the chipped lip is brighter where fresh edge is exposed.
                var h = mix(0.35, 0.0, bare) + grit * 0.20
                r += chipEdge * 16; g += chipEdge * 16; b += chipEdge * 14
                h += chipEdge * 0.25

                // Expansion joints on the 3 m grid, packed with grit.
                let djx = Double(min(x, S - x))
                let djy = Double(min(y, S - y))
                let cut = 1 - smoothstep(1.0, 3.5, min(djx, djy))
                r -= cut * 34; g -= cut * 34; b -= cut * 32
                h -= cut * 2.0
                rough += cut * 0.06

                // Damp in the low spots. This is the theme's sheen: not pooled
                // water like level 1, just a film that never dries.
                let low = 1 - smoothstep(0.24, 0.44, wearField)
                r -= low * 16; g -= low * 15; b -= low * 11
                rough -= low * 0.52
                h -= low * 0.15

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        var sr = Mulberry32(seed: 515)
        let edgeNoise = ValueNoise(seed: 516, period: 64)
        for _ in 0..<10 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 14 + sr.nextUnit() * 42, aspect: 0.6 + sr.nextUnit() * 0.5,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.5, noise: edgeNoise,
                   r: 16, g: 14, b: 12, alpha: 0.22)
        }
        // Wheel tracks, which polish the enamel where they run.
        for _ in 0..<8 {
            let sx = sr.nextUnit() * Double(S)
            let sy = sr.nextUnit() * Double(S)
            let ang = sr.nextUnit() * 6.28
            let len = 60 + sr.nextUnit() * 180
            c.smear(x0: sx, y0: sy, x1: sx + cos(ang) * len, y1: sy + sin(ang) * len,
                    width: 2 + sr.nextUnit() * 4,
                    r: 34, g: 32, b: 30, alpha: 0.18)
        }
        let trackWear = c.takeWear()
        foldWear(trackWear, intoRoughness: &rmap, delta: -0.12)

        c.specks(count: 600, seed: 517, minRadius: 0.5, maxRadius: 1.5,
                 r: 66, g: 64, b: 58, alpha: 0.3)
        let gritWear = c.takeWear()
        foldWear(gritWear, intoRoughness: &rmap, delta: 0.06)

        c.cracks(count: 6, seed: 518, r: 20, g: 18, b: 14, alpha: 0.40, maxWidth: 1.2)
        let crackWear = c.takeWear()
        foldWear(crackWear, intoHeight: &hmap, delta: -1.1)
        foldWear(crackWear, intoRoughness: &rmap, delta: 0.06)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 1.8),
                               roughness: rmap)
    }

    // MARK: - Level 37: Poolrooms

    /// Glazed ceramic wall and floor tile.
    ///
    /// 512² over a 1.5 m repeat — 2.9 mm to a texel, 128-texel tiles. This is
    /// the surface that gains most from GGX and the one that most needed the
    /// roughness rework: glaze at 0.075 against grout at 0.86 is the widest
    /// specular contrast in the game, and the old map ran the glaze at 0.27
    /// with a soft pillow normal, which read as wet plastic.
    ///
    /// Three things make a wall of tile look tiled rather than printed, and all
    /// three are per-tile rather than per-texel: each tile has its own glaze
    /// tint, its own gloss, and — the one that matters most — its own fraction
    /// of a degree of tilt, so they glint one at a time instead of together.
    public static func poolTile() -> SurfaceTextures {
        let S = 512, TILE = 128
        let groutHalf = 3.5                 // 7-texel joint, ~2 cm
        var c = TextureCanvas(size: S)
        let fine = FractalNoise(seed: 701, base: 64, octaves: 2)
        let mid = FractalNoise(seed: 702, base: 16, octaves: 3)
        let craze = FractalNoise(seed: 703, base: 64, octaves: 2)
        let pit = FractalNoise(seed: 704, base: 128, octaves: 2)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            let gy = y % TILE
            let ty = y / TILE
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let gx = x % TILE
                let tx = x / TILE

                // Texels from the joint centre, symmetric across the boundary.
                let dj = Double(min(min(gx, TILE - gx), min(gy, TILE - gy)))
                let grout = 1 - smoothstep(groutHalf - 0.5, groutHalf + 1.5, dj)
                // The glaze rolls over the last few millimetres of the tile and
                // is dead flat across the rest. The old whole-tile dome gave a
                // pillow; this gives the hard rim highlight that reads as fired
                // ceramic.
                let face = smoothstep(groutHalf, groutHalf + 5.0, dj)

                let fn = fine.signed(u, v)
                let wetField = mid(u, v)
                let tint = (ProceduralHash.unit(tx, ty, 711) - 0.5) * 9
                let gloss = (ProceduralHash.unit(tx, ty, 712) - 0.5) * 0.05

                // --- glaze ---
                var tileTone = 228 + tint + fn * 4
                // Reference: glazed ceramic/porcelain 0.05–0.25. Clean glaze
                // sits at the bottom of that; the rim, where the glaze thinned
                // over the edge, is measurably duller.
                var tileRough = 0.075 + gloss + (1 - face) * 0.07
                // No tiler sets a wall dead flat.
                let tiltX = (ProceduralHash.unit(tx, ty, 713) - 0.5) * 1.4
                let tiltY = (ProceduralHash.unit(tx, ty, 714) - 0.5) * 1.4
                let fu = Double(gx) / Double(TILE) - 0.5
                let fv = Double(gy) / Double(TILE) - 0.5
                var tileH = 1.6 + face * (tiltX * fu + tiltY * fv)

                // Craze lines: the glaze cracks in a fine web as the body moves
                // under it. Almost invisible in colour — but they hold dirt,
                // and roughness is where crazing actually shows.
                let cz = 1 - smoothstep(0.0, 0.010, abs(craze(u, v) - 0.5))
                tileTone -= cz * 10
                tileRough += cz * 0.24
                tileH -= cz * 0.25

                // Limescale creeping out of the joints, which is what a room
                // that has been wet for decades looks like.
                let scale = (1 - face) * smoothstep(0.5, 0.75, wetField)
                tileTone += scale * 12
                tileRough += scale * 0.30

                // --- grout ---
                let pitting = pit.signed(u, v)
                var groutTone = 152 + pitting * 9 + fn * 4
                // Cementitious grout, unsealed: reference 0.60–0.80 clean.
                // This has never been sealed and never been dry.
                var groutRough = 0.86 + pitting * 0.05
                var groutH = 0.0 + pitting * 0.18
                // Mildew in the joints — the Poolrooms detail. Only in the
                // grout, because that is the only porous thing in the room.
                let mildew = smoothstep(0.56, 0.74, wetField)
                groutTone -= mildew * 46
                groutRough += mildew * 0.06
                groutH += mildew * 0.12

                var tone = mix(tileTone, groutTone, grout)
                var rough = mix(tileRough, groutRough, grout)
                var h = mix(tileH, groutH, grout)

                // A chipped corner on roughly one tile in eight, exposing the
                // unglazed biscuit: lighter, matte, and below the glaze line.
                let chipRoll = ProceduralHash.unit(tx, ty, 715)
                if chipRoll > 0.86 {
                    var cornerX = Double(gx)
                    var cornerY = Double(gy)
                    if ProceduralHash.unit(tx, ty, 716) > 0.5 { cornerX = Double(TILE - gx) }
                    if ProceduralHash.unit(tx, ty, 717) > 0.5 { cornerY = Double(TILE - gy) }
                    let cd = (cornerX * cornerX + cornerY * cornerY).squareRoot()
                    let rad = 7 + (chipRoll - 0.86) * 90
                    let bite = (1 - smoothstep(rad - 3, rad, cd)) * face
                    if bite > 0 {
                        tone = mix(tone, 206, bite)
                        rough = mix(rough, 0.80, bite)
                        h -= bite * 1.1
                    }
                }

                let mildewMix = grout * mildew
                let r = tone
                var g = tone * 0.995
                var b = tone * 0.975
                if mildewMix > 0 {
                    // Biofilm pulls green, not just dark.
                    g += mildewMix * 8
                    b -= mildewMix * 4
                }

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: r, g: g, b: b)
            }
        }

        var sr = Mulberry32(seed: 705)
        let edgeNoise = ValueNoise(seed: 706, period: 64)
        // Mineral runs where water has tracked down the wall for years.
        for i in 0..<10 {
            c.runoff(x: sr.nextUnit() * Double(S), top: sr.nextUnit() * Double(S) * 0.4,
                     length: 60 + sr.nextUnit() * 200, width: 2 + sr.nextUnit() * 4,
                     wander: 4, seed: 720 &+ UInt32(i),
                     r: 208, g: 210, b: 202, alpha: 0.13)
        }
        let scaleWear = c.takeWear()
        // Scale is the one thing that can kill the gloss on a glazed tile, and
        // it is the reason a wet room does not read as a showroom.
        foldWear(scaleWear, intoRoughness: &rmap, delta: 0.42)
        foldWear(scaleWear, intoHeight: &hmap, delta: 0.12)

        for _ in 0..<8 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 14 + sr.nextUnit() * 30, aspect: 0.7 + sr.nextUnit() * 0.4,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.45, noise: edgeNoise,
                   r: 122, g: 132, b: 130, alpha: 0.07)
        }
        let filmWear = c.takeWear()
        foldWear(filmWear, intoRoughness: &rmap, delta: 0.18)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 2.2),
                               roughness: rmap)
    }

    /// Small glazed mosaic on the pool-room ceiling.
    ///
    /// 256² over a 1.2 m repeat — 4.7 mm to a texel, 16-texel tiles, so about
    /// 75 mm mosaic with a 9 mm joint. The ceiling is what the volumetric
    /// lighting plays across, so it is glazed (0.20) rather than the flat 0.67
    /// it used to be — but not as glossy as the walls, because it has taken
    /// more condensation than anything else in the room.
    public static func poolCeiling() -> SurfaceTextures {
        let S = 256, TILE = 16
        var c = TextureCanvas(size: S)
        let mid = FractalNoise(seed: 731, base: 8, octaves: 3)
        let fine = FractalNoise(seed: 732, base: 64, octaves: 2)
        var hmap = [Float](repeating: 0, count: S * S)
        var rmap = [UInt8](repeating: 0, count: S * S)

        for y in 0..<S {
            let v = Double(y) / Double(S)
            let gy = y % TILE
            let ty = y / TILE
            for x in 0..<S {
                let u = Double(x) / Double(S)
                let gx = x % TILE
                let tx = x / TILE

                let dj = Double(min(min(gx, TILE - gx), min(gy, TILE - gy)))
                let grout = 1 - smoothstep(0.4, 1.6, dj)
                let face = smoothstep(1.0, 3.0, dj)

                let fn = fine.signed(u, v)
                let damp = mid(u, v)
                let tint = (ProceduralHash.unit(tx, ty, 741) - 0.5) * 17
                let gloss = (ProceduralHash.unit(tx, ty, 742) - 0.5) * 0.07

                var tileTone = 156 + tint + fn * 4
                var tileRough = 0.20 + gloss + (1 - face) * 0.10
                let tiltX = (ProceduralHash.unit(tx, ty, 743) - 0.5) * 0.5
                let tiltY = (ProceduralHash.unit(tx, ty, 744) - 0.5) * 0.5
                let fu = Double(gx) / Double(TILE) - 0.5
                let fv = Double(gy) / Double(TILE) - 0.5
                var tileH = 0.9 + face * (tiltX * fu + tiltY * fv)

                // Condensation staining, heaviest where the mid field peaks.
                let stain = smoothstep(0.52, 0.78, damp)
                tileTone -= stain * 22
                tileRough += stain * 0.26
                tileH -= stain * 0.05

                let groutTone = 96 + fn * 6 - stain * 20
                let groutRough = 0.82 + fn * 0.04
                let groutH = 0.0 + fn * 0.10

                let tone = mix(tileTone, groutTone, grout)
                let rough = mix(tileRough, groutRough, grout)
                let h = mix(tileH, groutH, grout)

                hmap[y * S + x] = Float(h)
                rmap[y * S + x] = rough8(rough)
                c.set(x, y, r: tone, g: tone, b: tone * 1.03)
            }
        }

        var sr = Mulberry32(seed: 733)
        let edgeNoise = ValueNoise(seed: 734, period: 32)
        for _ in 0..<7 {
            c.blot(x: sr.nextUnit() * Double(S), y: sr.nextUnit() * Double(S),
                   radius: 8 + sr.nextUnit() * 22, aspect: 0.7 + sr.nextUnit() * 0.5,
                   rotation: sr.nextUnit() * 3.14, wobble: 0.55, noise: edgeNoise,
                   r: 104, g: 108, b: 100, alpha: 0.16)
        }
        let stainWear = c.takeWear()
        foldWear(stainWear, intoRoughness: &rmap, delta: 0.30)

        return SurfaceTextures(size: S, albedo: c.pixels,
                               normal: normalMap(from: hmap, size: S, strength: 2.4),
                               roughness: rmap)
    }
}
