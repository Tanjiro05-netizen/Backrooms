import XCTest
@testable import BackroomsCore

/// Covers the procedural texture synthesis.
///
/// These are not fixture-compared against the JS canvas: the base material
/// loops are a faithful port, but the grime passes on top are reimplemented
/// (see `TextureCanvas`), so byte equality would be asserting a lie. What is
/// asserted instead is everything that would make a surface visibly wrong on
/// device — buffers the wrong length, normals that are not unit vectors,
/// roughness outside range, textures that do not tile, or a floor that comes
/// out the colour of the wrong level.
final class TextureTests: XCTestCase {

    /// Synthesis is the slow part of these tests, so pay for it once.
    private static let themes: [LevelSpec.Theme: ThemeTextures] = {
        var out: [LevelSpec.Theme: ThemeTextures] = [:]
        for theme in [LevelSpec.Theme.lobby, .warehouse, .pipes, .pool] {
            out[theme] = ProceduralTextures.forTheme(theme)
        }
        return out
    }()

    private func surfaces(_ theme: LevelSpec.Theme) -> [(String, SurfaceTextures)] {
        let t = TextureTests.themes[theme]!
        return [("wall", t.wall), ("floor", t.floor), ("ceiling", t.ceiling)]
    }

    // MARK: - Noise

    /// Everything tiles because the noise lattice wraps. If this breaks, every
    /// surface in the game grows a seam.
    func testValueNoiseWrapsAtItsPeriod() {
        let n = ValueNoise(seed: 42, period: 16)
        for i in 0..<20 {
            let x = Double(i) * 0.7, y = Double(i) * 1.3
            XCTAssertEqual(n(x, y), n(x + 16, y), accuracy: 1e-12)
            XCTAssertEqual(n(x, y), n(x, y + 16), accuracy: 1e-12)
            XCTAssertEqual(n(x, y), n(x - 32, y + 16), accuracy: 1e-12)
        }
    }

    func testValueNoiseAndFbmStayInRange() {
        let n = ValueNoise(seed: 7, period: 32)
        var lo = 1.0, hi = 0.0
        for i in 0..<400 {
            let v = n(Double(i) * 0.37, Double(i) * 0.11)
            lo = min(lo, v); hi = max(hi, v)
            XCTAssertFalse(v.isNaN)
        }
        XCTAssertGreaterThanOrEqual(lo, 0)
        XCTAssertLessThanOrEqual(hi, 1)
        XCTAssertLessThan(lo, 0.35, "noise never gets dark — the lattice is not varying")
        XCTAssertGreaterThan(hi, 0.65, "noise never gets bright")

        // fbm sums 0.5 + 0.25 + 0.125 of a [0,1] signal, so it cannot exceed
        // that — the web build relies on the un-normalised range.
        for i in 0..<200 {
            let f = n.fbm(Double(i) * 0.21, Double(i) * 0.63, 3)
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThanOrEqual(f, 0.875 + 1e-9)
        }
    }

    // MARK: - Buffer shape

    func testEverySurfaceHasWellFormedBuffers() {
        for theme in [LevelSpec.Theme.lobby, .warehouse, .pipes, .pool] {
            for (name, s) in surfaces(theme) {
                let label = "\(theme.rawValue).\(name)"
                XCTAssertGreaterThan(s.size, 0, label)
                XCTAssertEqual(s.albedo.count, s.size * s.size * 4, "\(label) albedo")
                XCTAssertEqual(s.normal.count, s.size * s.size * 4, "\(label) normal")
                XCTAssertEqual(s.roughness.count, s.size * s.size, "\(label) roughness (single channel)")
                // Fully opaque: the level pass does not blend.
                for i in stride(from: 3, to: s.albedo.count, by: 4 * 977) {
                    XCTAssertEqual(s.albedo[i], 255, "\(label) alpha")
                }
            }
        }
    }

    /// A normal map whose vectors are not unit length lights wrong, and one
    /// with z ≤ 0 turns the surface inside out.
    func testNormalMapsAreUnitVectorsFacingOut() {
        for theme in [LevelSpec.Theme.lobby, .warehouse, .pipes, .pool] {
            for (name, s) in surfaces(theme) {
                var checked = 0
                for i in stride(from: 0, to: s.normal.count, by: 4 * 613) {
                    let nx = Double(s.normal[i]) / 255 * 2 - 1
                    let ny = Double(s.normal[i + 1]) / 255 * 2 - 1
                    let nz = Double(s.normal[i + 2]) / 255 * 2 - 1
                    let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                    XCTAssertEqual(len, 1, accuracy: 0.03,
                                   "\(theme.rawValue).\(name) normal is not unit length")
                    XCTAssertGreaterThan(nz, 0,
                                         "\(theme.rawValue).\(name) normal points into the surface")
                    checked += 1
                }
                XCTAssertGreaterThan(checked, 10)
            }
        }
    }

    // MARK: - Material identity

    /// Level 0 is the one everybody recognises: yellow walls, and a baseboard
    /// that is markedly darker than the wall above it.
    func testLobbyWallIsYellowWithADarkBaseboard() {
        let wall = TextureTests.themes[.lobby]!.wall
        let S = wall.size

        func rowLuma(_ y: Int) -> (r: Double, g: Double, b: Double) {
            var r = 0.0, g = 0.0, b = 0.0
            for x in 0..<S {
                let i = (y * S + x) * 4
                r += Double(wall.albedo[i]); g += Double(wall.albedo[i + 1]); b += Double(wall.albedo[i + 2])
            }
            return (r / Double(S), g / Double(S), b / Double(S))
        }

        let mid = rowLuma(S / 2)
        XCTAssertGreaterThan(mid.r, mid.g, "wallpaper should be warm")
        XCTAssertGreaterThan(mid.g, mid.b, "wallpaper should be yellow, not pink")
        XCTAssertGreaterThan(mid.r, 150, "wallpaper is too dark to read as the lobby")

        let baseboard = rowLuma(S - 5)
        XCTAssertLessThan(baseboard.r, mid.r * 0.7, "no baseboard band at the bottom of the wall")
    }

    /// The drop ceiling has to have grout between the panels, or it reads as
    /// one flat sheet and the room loses its scale.
    func testLobbyCeilingHasPanelSeams() {
        let ceil = TextureTests.themes[.lobby]!.ceiling
        let S = ceil.size
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * S + x) * 4
            return (Double(ceil.albedo[i]) + Double(ceil.albedo[i + 1]) + Double(ceil.albedo[i + 2])) / 3
        }
        // x = 0 and x = TILE are seam columns; halfway between is panel face.
        XCTAssertLessThan(luma(1, 100), luma(100, 100) * 0.6, "vertical seam missing")
        XCTAssertLessThan(luma(100, 1), luma(100, 100) * 0.6, "horizontal seam missing")
    }

    /// Puddles and wet paint are the only reason the spec lobe exists; if the
    /// roughness map is flat, levels 1 and 2 lose their sheen entirely.
    func testWetSurfacesVaryTheirRoughness() {
        // Level 1's standing puddles go nearly mirror-smooth.
        let warehouse = TextureTests.themes[.warehouse]!.floor
        XCTAssertLessThan(warehouse.roughness.min() ?? 255, 120, "level 1 has no puddles")
        XCTAssertGreaterThan(warehouse.roughness.max() ?? 0, 200, "level 1 is glossy everywhere")

        // Level 2's sheen is subtler — damp in the low spots, not pooled — so
        // what matters there is that wet and dry differ at all.
        let pipes = TextureTests.themes[.pipes]!.floor
        let lo = Int(pipes.roughness.min() ?? 255), hi = Int(pipes.roughness.max() ?? 0)
        XCTAssertGreaterThan(hi - lo, 50, "level 2 floor is uniformly rough — no damp patches")

        // Pool tile is glossy by nature; the grout is the rough part.
        XCTAssertLessThan(TextureTests.themes[.pool]!.wall.roughness.min() ?? 255, 100)
        XCTAssertGreaterThan(TextureTests.themes[.pool]!.wall.roughness.max() ?? 0, 180)
    }

    func testPoolFloorIsTintedColderThanItsWall() {
        let pool = TextureTests.themes[.pool]!
        XCTAssertTrue(pool.floorIsTinted)
        XCTAssertLessThan(pool.floorTintR, pool.floorTintB,
                          "the pool floor tint should pull blue, not red")
        XCTAssertLessThan(pool.floorTintR, 1.0)
    }

    /// Tile scale is per-surface. Using one repeat for both — as the renderer
    /// briefly did — stretches ceiling panels to twice their size on level 0.
    func testTileScalesAreDistinctAndSane() {
        for theme in [LevelSpec.Theme.lobby, .warehouse, .pipes, .pool] {
            let t = TextureTests.themes[theme]!
            XCTAssertGreaterThan(t.floorTile, 0)
            XCTAssertGreaterThan(t.ceilingTile, 0)
            XCTAssertLessThan(t.floorTile, 10)
            XCTAssertLessThan(t.ceilingTile, 10)
        }
        XCTAssertNotEqual(TextureTests.themes[.lobby]!.floorTile,
                          TextureTests.themes[.lobby]!.ceilingTile)
    }

    // MARK: - Determinism

    /// Same seed, same sheet — otherwise a reloaded level would not look like
    /// the one you just walked out of.
    func testGenerationIsDeterministic() {
        let a = ProceduralTextures.warehouseCeiling()
        let b = ProceduralTextures.warehouseCeiling()
        XCTAssertEqual(Fnv64.hash(bytes: a.albedo), Fnv64.hash(bytes: b.albedo))
        XCTAssertEqual(Fnv64.hash(bytes: a.normal), Fnv64.hash(bytes: b.normal))
        XCTAssertEqual(Fnv64.hash(bytes: a.roughness), Fnv64.hash(bytes: b.roughness))
    }

    // MARK: - Canvas primitives

    func testStainDarkensItsCentreAndFadesToNothingAtTheRim() {
        var c = TextureCanvas(size: 64)
        for y in 0..<64 { for x in 0..<64 { c.set(x, y, r: 200, g: 200, b: 200) } }
        c.stain(x: 32, y: 32, radius: 16, aspect: 1, rotation: 0,
                r: 0, g: 0, b: 0, alpha: 0.8)

        func luma(_ x: Int, _ y: Int) -> Double { Double(c.pixels[(y * 64 + x) * 4]) }
        XCTAssertLessThan(luma(32, 32), 60, "stain centre is not opaque")
        XCTAssertGreaterThan(luma(32, 40), luma(32, 32), "no falloff toward the rim")
        XCTAssertEqual(luma(0, 0), 200, accuracy: 0.5, "stain leaked past its radius")
    }

    /// Overlays wrap, so a stain near an edge continues on the far side rather
    /// than being clipped into a visible straight cut.
    func testOverlaysWrapAcrossTheSeam() {
        var c = TextureCanvas(size: 64)
        for y in 0..<64 { for x in 0..<64 { c.set(x, y, r: 200, g: 200, b: 200) } }
        c.stain(x: 1, y: 32, radius: 12, aspect: 1, rotation: 0,
                r: 0, g: 0, b: 0, alpha: 0.9)
        let farSide = Double(c.pixels[(32 * 64 + 62) * 4])
        XCTAssertLessThan(farSide, 190, "stain did not wrap around the tile seam")
    }

    func testNormalMapOfAFlatHeightFieldIsFlat() {
        let flat = [Float](repeating: 128, count: 32 * 32)
        let n = normalMap(from: flat, size: 32, strength: 2.0)
        for i in stride(from: 0, to: n.count, by: 4) {
            XCTAssertEqual(n[i], 128, "flat height should give x = 0")
            XCTAssertEqual(n[i + 1], 128, "flat height should give y = 0")
            XCTAssertEqual(n[i + 2], 255, "flat height should give z = 1")
        }
    }

    /// A ramp in x must tilt the normal in x and leave y alone — this is the
    /// check that catches a transposed or sign-flipped derivative.
    func testNormalMapRespondsToASlopeInTheRightAxis() {
        let size = 32
        var ramp = [Float](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { ramp[y * size + x] = Float(x) * 4 } }
        let n = normalMap(from: ramp, size: size, strength: 1.0)
        // Sample away from the wrap column, where the ramp jumps back.
        let i = (16 * size + 16) * 4
        XCTAssertLessThan(n[i], 128, "a surface rising with x must tilt its normal −x")
        XCTAssertEqual(n[i + 1], 128, "a slope in x must not move the y component")
    }
}
