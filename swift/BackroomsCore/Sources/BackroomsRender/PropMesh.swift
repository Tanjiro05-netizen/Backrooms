import Foundation
import BackroomsCore

/// The objectives, as geometry — plus the per-theme set dressing that stops a
/// room reading as an empty box.
///
/// Split into a dark pass and a bright pass because a cassette lying on brown
/// carpet and a doorway that has to be spotted from across a room want opposite
/// treatments — and one texture is bound per draw. The dressing rides the same
/// two passes rather than adding a third: everything here is either a dark
/// object (steel, rubber, a shadowed recess) or a pale one (a diffuser, a
/// galvanised pipe, poolside tile), and two draws is two draws.
public enum PropMesh {

    /// A VHS cassette: the web build's 0.30 × 0.055 × 0.18 box, lying flat.
    public static let tapeHalf = (x: Float(0.15), y: Float(0.0275), z: Float(0.09))

    public static let doorWidth: Float = 1.30
    public static let doorHeight: Float = 2.20
    private static let jamb: Float = 0.13
    private static let depth: Float = 0.14

    /// Everything drawn near-black: the cassette bodies, the void inside the
    /// doorway, and the dark half of the set dressing.
    ///
    /// `dressing` is optional and defaults to nothing, so a caller that has not
    /// built it yet keeps the behaviour it had. Build it once per floor with
    /// `dressing(map:)` and hand the same value back on every rebuild — it does
    /// not change when a tape is picked up.
    public static func dark(tapes: [Objectives.Tape], exit: Objectives.Exit?,
                            dressing: Dressing? = nil,
                            groundY: (Double, Double) -> Double) -> InterleavedMesh {
        var b = MeshBuilder(reservingBoxes: tapes.count + 1)
        for tape in tapes where !tape.found {
            let gy = Float(groundY(tape.x, tape.z))
            b.addBox(originX: Float(tape.x), originY: gy, originZ: Float(tape.z),
                     yaw: Float(tape.yaw),
                     localX: 0, localY: tapeHalf.y + 0.01, localZ: 0,
                     halfX: tapeHalf.x, halfY: tapeHalf.y, halfZ: tapeHalf.z)
        }
        if let exit {
            // The void reads as depth behind the frame — a door that goes
            // somewhere, rather than a rectangle painted on a wall.
            let gy = Float(groundY(exit.x, exit.z))
            let inner = doorWidth / 2 - jamb
            b.addBox(originX: Float(exit.x), originY: gy, originZ: Float(exit.z), yaw: 0,
                     localX: 0, localY: doorHeight / 2, localZ: -depth,
                     halfX: inner, halfY: doorHeight / 2 - jamb / 2, halfZ: 0.04)
        }
        return merge(b.mesh, dressing?.dark)
    }

    /// Everything drawn bright: the door frame, a small riser under each tape so
    /// a black cassette on a dark floor still catches the eye, and the pale half
    /// of the set dressing.
    public static func bright(tapes: [Objectives.Tape], exit: Objectives.Exit?,
                              dressing: Dressing? = nil,
                              groundY: (Double, Double) -> Double) -> InterleavedMesh {
        var b = MeshBuilder(reservingBoxes: tapes.count + 3)
        for tape in tapes where !tape.found {
            let gy = Float(groundY(tape.x, tape.z))
            // The spine label, standing just proud of the cassette body.
            b.addBox(originX: Float(tape.x), originY: gy, originZ: Float(tape.z),
                     yaw: Float(tape.yaw),
                     localX: 0, localY: tapeHalf.y * 2 + 0.012, localZ: 0,
                     halfX: tapeHalf.x * 0.62, halfY: 0.004, halfZ: tapeHalf.z * 0.5)
        }
        if let exit {
            let gy = Float(groundY(exit.x, exit.z))
            let half = doorWidth / 2
            // Two posts and a lintel. The door swings on `openTime`, but the
            // frame never moves, so it is the thing you actually navigate to.
            for side in [Float(-1), 1] {
                b.addBox(originX: Float(exit.x), originY: gy, originZ: Float(exit.z), yaw: 0,
                         localX: side * (half - jamb / 2), localY: doorHeight / 2, localZ: 0,
                         halfX: jamb / 2, halfY: doorHeight / 2, halfZ: depth)
            }
            b.addBox(originX: Float(exit.x), originY: gy, originZ: Float(exit.z), yaw: 0,
                     localX: 0, localY: doorHeight - jamb / 2, localZ: 0,
                     halfX: half, halfY: jamb / 2, halfZ: depth)
        }
        return merge(b.mesh, dressing?.bright)
    }

    private static func merge(_ base: InterleavedMesh, _ extra: InterleavedMesh?) -> InterleavedMesh {
        guard let extra, !extra.isEmpty else { return base }
        return InterleavedMesh(rawVertices: base.vertices + extra.vertices)
    }

    // MARK: - Set dressing

    /// A floor's static clutter, already split across the two prop draws.
    ///
    /// It depends only on the map, so it is built once per floor and reused
    /// for every objective rebuild.
    public struct Dressing {
        public let dark: InterleavedMesh
        public let bright: InterleavedMesh
        /// What this floor's dressing cost, for budgeting against a phone.
        public var triangleCount: Int { (dark.vertexCount + bright.vertexCount) / 3 }
    }

    /// Builds the theme's set dressing. Deterministic for a given map: the
    /// stream is seeded from the map's own shape, so the same floor always
    /// comes back furnished the same way, and it is a stream of its own so that
    /// adding a crate cannot move a tape.
    ///
    /// None of this has colliders — the collider buckets are pinned byte-exact
    /// against the web build — so everything is either against a wall, on the
    /// ceiling, or (crates, barrels) inside an open zone where there is room to
    /// walk around it.
    public static func dressing(map: GameMap) -> Dressing {
        var dark = MeshBuilder(reservingVertices: 40_000)
        var bright = MeshBuilder(reservingVertices: 40_000)
        var rng = Mulberry32(seed: seed(for: map))

        switch map.spec.theme {
        case .lobby:     lobby(map: map, rng: &rng, dark: &dark, bright: &bright)
        case .warehouse: warehouse(map: map, rng: &rng, dark: &dark, bright: &bright)
        case .pipes:     pipes(map: map, rng: &rng, dark: &dark, bright: &bright)
        case .pool:      pool(map: map, rng: &rng, dark: &dark, bright: &bright)
        }
        return Dressing(dark: dark.mesh, bright: bright.mesh)
    }

    private static func seed(for map: GameMap) -> UInt32 {
        let themeSalt: UInt32
        switch map.spec.theme {
        case .lobby: themeSalt = 11
        case .warehouse: themeSalt = 23
        case .pipes: themeSalt = 41
        case .pool: themeSalt = 67
        }
        return LevelSpec.baseSeed
            &+ UInt32(truncatingIfNeeded: map.grid) &* 7919
            &+ UInt32(truncatingIfNeeded: map.spawnX &* 131 &+ map.spawnZ &* 17)
            &+ themeSalt &* 104_729
    }

    // MARK: Wall faces

    /// One visible face of one solid wall segment.
    ///
    /// Almost every piece of dressing hangs off a wall, and the map stores wall
    /// *edges*, not faces — so this resolves the two-sidedness once: where the
    /// segment runs, which way this face looks, and which open cell you would
    /// be standing in to see it.
    private struct WallFace {
        /// The segment runs along X (a horizontal edge); otherwise along Z.
        let alongX: Bool
        /// Extent along the run, and the wall's centre line on the other axis.
        let a0: Double, a1: Double, fixed: Double
        /// +1 if the face looks toward increasing `fixed`, −1 otherwise.
        let sign: Double
        /// The open cell in front of the face.
        let cellX: Int, cellZ: Int

        var span: Double { a1 - a0 }
    }

    /// Every solid wall face on the floor, in a fixed order. Doorway segments
    /// (type 2) are skipped so nothing is ever hung across a door.
    private static func wallFaces(map: GameMap) -> [WallFace] {
        let g = map.grid, cs = map.spec.cellSize
        var out: [WallFace] = []
        out.reserveCapacity(2048)

        for z in 0...g {
            for x in 0..<g {
                guard map.hWall(x, z) == 1 else { continue }
                let a0 = (Double(x) - Double(g) / 2) * cs
                let fixed = (Double(z) - Double(g) / 2) * cs
                if z > 0, map.pillarMask[x + (z - 1) * g] == 0 {
                    out.append(WallFace(alongX: true, a0: a0, a1: a0 + cs, fixed: fixed,
                                        sign: -1, cellX: x, cellZ: z - 1))
                }
                if z < g, map.pillarMask[x + z * g] == 0 {
                    out.append(WallFace(alongX: true, a0: a0, a1: a0 + cs, fixed: fixed,
                                        sign: 1, cellX: x, cellZ: z))
                }
            }
        }
        for z in 0..<g {
            for x in 0...g {
                guard map.vWall(x, z) == 1 else { continue }
                let a0 = (Double(z) - Double(g) / 2) * cs
                let fixed = (Double(x) - Double(g) / 2) * cs
                if x > 0, map.pillarMask[x - 1 + z * g] == 0 {
                    out.append(WallFace(alongX: false, a0: a0, a1: a0 + cs, fixed: fixed,
                                        sign: -1, cellX: x - 1, cellZ: z))
                }
                if x < g, map.pillarMask[x + z * g] == 0 {
                    out.append(WallFace(alongX: false, a0: a0, a1: a0 + cs, fixed: fixed,
                                        sign: 1, cellX: x, cellZ: z))
                }
            }
        }
        return out
    }

    /// World position `t` metres along a face and `out` metres clear of its
    /// surface. The wall's own skin is half a wall thickness off its centre
    /// line, so props sit on the plaster rather than inside it.
    private static func facePoint(_ f: WallFace, t: Double, out: Double) -> (x: Double, z: Double) {
        let surface = f.fixed + f.sign * (LevelGeometry.wallThickness / 2 + out)
        return f.alongX ? (x: f.a0 + t, z: surface) : (x: surface, z: f.a0 + t)
    }

    /// Half-extents for a box that is `along` metres long down the run and
    /// `thick` metres deep into the wall.
    private static func faceHalf(_ f: WallFace, along: Double, thick: Double)
        -> (halfX: Float, halfZ: Float) {
        f.alongX ? (halfX: Float(along), halfZ: Float(thick))
                 : (halfX: Float(thick), halfZ: Float(along))
    }

    private static func runAxis(_ f: WallFace) -> MeshBuilder.Axis { f.alongX ? .x : .z }

    private static func nearSpawn(_ map: GameMap, _ cx: Int, _ cz: Int, _ radius: Int) -> Bool {
        abs(cx - map.spawnX) + abs(cz - map.spawnZ) < radius
    }

    // A note that applies to every offset below: nothing here is ever exactly
    // coplanar with the floor, the ceiling or a wall skin. Props are drawn
    // double-sided, so a shared plane is not a hidden face — it is a z-fighting
    // shimmer, and the tape pass makes shimmer worse, not better. Where two
    // props stack, they interpenetrate by a centimetre for the same reason.

    // MARK: Lobby

    /// Level 0: recessed ceiling troffers, wall vents, and skirting board.
    ///
    /// The lobby's horror is that it is an office with nobody in it, so the
    /// dressing is all building fabric — the things that would be there anyway.
    /// Skirting in particular is what gives SSAO a corner to find: a wall
    /// meeting a floor at a hard 90° reads as a painted seam, a wall meeting a
    /// skirting board reads as a room.
    private static func lobby(map: GameMap, rng: inout Mulberry32,
                              dark: inout MeshBuilder, bright: inout MeshBuilder) {
        let wh = Float(map.spec.wallHeight)
        let g = map.grid

        // Troffers: a dark backing plate flush with the ceiling and a pale
        // diffuser hanging just below it.
        var lights = 0
        for f in map.fixtures {
            guard lights < 460 else { break }
            let x = Float(map.cellWorldX(f.cellX)), z = Float(map.cellWorldZ(f.cellZ))
            dark.addBox(originX: x, originY: 0, originZ: z, yaw: 0,
                        localX: 0, localY: wh - 0.06, localZ: 0,
                        halfX: 1.24, halfY: 0.05, halfZ: 0.66)
            bright.addBox(originX: x, originY: 0, originZ: z, yaw: 0,
                          localX: 0, localY: wh - 0.145, localZ: 0,
                          halfX: 1.15, halfY: 0.035, halfZ: 0.575)
            lights += 1
        }

        let faces = wallFaces(map: map)

        // Vents, high on the wall: a dark recess with three pale louvres.
        var vents = 0
        for f in faces {
            guard vents < 40 else { break }
            guard rng.nextUnit() < 0.05 else { continue }
            let t = f.span * 0.5
            let p = facePoint(f, t: t, out: 0.0)
            let body = faceHalf(f, along: 0.44, thick: 0.03)
            let y = wh - 0.72
            dark.addBox(originX: Float(p.x), originY: 0, originZ: Float(p.z), yaw: 0,
                        localX: 0, localY: y, localZ: 0,
                        halfX: body.halfX, halfY: 0.28, halfZ: body.halfZ)
            let slat = faceHalf(f, along: 0.40, thick: 0.02)
            let proud = facePoint(f, t: t, out: 0.035)
            for k in -1...1 {
                bright.addBox(originX: Float(proud.x), originY: 0, originZ: Float(proud.z), yaw: 0,
                              localX: 0, localY: y + Float(k) * 0.13, localZ: 0,
                              halfX: slat.halfX, halfY: 0.030, halfZ: slat.halfZ)
            }
            vents += 1
        }

        // Skirting. Rooms get it unconditionally — that is where you see the
        // wall meet the floor — and corridors get a share, up to a budget.
        var skirts = 0
        for f in faces {
            guard skirts < 900 else { break }
            let inRoom = map.zoneMask[f.cellX + f.cellZ * g] != 0
            let roll = rng.nextUnit()
            guard inRoom || roll < 0.30 else { continue }
            // Set 1cm into the plaster so its back face is not on the wall
            // plane, and lifted clear of the floor plane for the same reason.
            let p = facePoint(f, t: f.span * 0.5, out: 0.020)
            let half = faceHalf(f, along: f.span * 0.5, thick: 0.030)
            bright.addBox(originX: Float(p.x), originY: 0, originZ: Float(p.z), yaw: 0,
                          localX: 0, localY: 0.058, localZ: 0,
                          halfX: half.halfX, halfY: 0.055, halfZ: half.halfZ)
            skirts += 1
        }
    }

    // MARK: Warehouse

    /// Level 1: crates on pallets, steel racking against the walls, drums, and
    /// the web build's pendant lamps (cord, shade, bulb) at every fixture.
    private static func warehouse(map: GameMap, rng: inout Mulberry32,
                                  dark: inout MeshBuilder, bright: inout MeshBuilder) {
        let g = map.grid
        let cs = map.spec.cellSize
        let wh = Float(map.spec.wallHeight)

        // Crates, following the web build's placement rule: open zones only,
        // clear of the spawn pocket, sometimes stacked two high.
        var crates = 0
        for z in 1..<(g - 1) {
            for x in 1..<(g - 1) {
                guard crates < 80 else { break }
                guard map.zoneMask[x + z * g] != 0, map.pillarMask[x + z * g] == 0 else { continue }
                guard !nearSpawn(map, x, z, 4) else { continue }
                guard rng.nextUnit() < 0.18 else { continue }

                let wx = map.cellWorldX(x) + (rng.nextUnit() - 0.5) * (cs - 2.4)
                let wz = map.cellWorldZ(z) + (rng.nextUnit() - 0.5) * (cs - 2.4)
                let s = Float(0.85 + rng.nextUnit() * 0.65)
                let yaw = Float(rng.nextUnit() * 0.6 - 0.3)
                let ox = Float(wx), oz = Float(wz)

                // A pallet under the crate. Cheap, and it gives the contact
                // shadow somewhere to land instead of a box floating on carpet.
                dark.addBox(originX: ox, originY: 0, originZ: oz, yaw: yaw,
                            localX: 0, localY: 0.062, localZ: 0,
                            halfX: s * 0.58, halfY: 0.06, halfZ: s * 0.58)
                bright.addBox(originX: ox, originY: 0, originZ: oz, yaw: yaw,
                              localX: 0, localY: 0.12 + s / 2, localZ: 0,
                              halfX: s / 2, halfY: s / 2, halfZ: s / 2)
                if rng.nextUnit() < 0.35 {
                    // Sunk a centimetre into the crate below rather than
                    // balanced exactly on it.
                    let s2 = s * 0.75
                    bright.addBox(originX: ox, originY: 0, originZ: oz, yaw: yaw + 0.4,
                                  localX: Float(rng.nextUnit() - 0.5) * 0.2,
                                  localY: 0.11 + s + s2 / 2,
                                  localZ: Float(rng.nextUnit() - 0.5) * 0.2,
                                  halfX: s2 / 2, halfY: s2 / 2, halfZ: s2 / 2)
                }
                crates += 1
            }
        }

        // Steel drums, upright, with two rolling hoops.
        var drums = 0
        for z in 1..<(g - 1) {
            for x in 1..<(g - 1) {
                guard drums < 28 else { break }
                guard map.zoneMask[x + z * g] != 0, map.pillarMask[x + z * g] == 0 else { continue }
                guard !nearSpawn(map, x, z, 4) else { continue }
                guard rng.nextUnit() < 0.05 else { continue }

                let wx = Float(map.cellWorldX(x) + (rng.nextUnit() - 0.5) * (cs - 2.0))
                let wz = Float(map.cellWorldZ(z) + (rng.nextUnit() - 0.5) * (cs - 2.0))
                dark.addCylinder(originX: wx, originY: 0, originZ: wz,
                                 localX: 0, localY: 0.452, localZ: 0,
                                 radius: 0.30, halfLength: 0.45,
                                 axis: .y, segments: 10, capped: true)
                for hoopY in [Float(0.22), 0.68] {
                    dark.addCylinder(originX: wx, originY: 0, originZ: wz,
                                     localX: 0, localY: hoopY, localZ: 0,
                                     radius: 0.315, halfLength: 0.03,
                                     axis: .y, segments: 10, capped: false)
                }
                drums += 1
            }
        }

        // Racking against the walls: four uprights, three shelves, and
        // sometimes a pallet of stock on one of them.
        let faces = wallFaces(map: map)
        let rackHeight = min(Float(3.0), wh - 0.9)
        var racks = 0
        for f in faces {
            guard racks < 26 else { break }
            // Deliberately not restricted to open zones: this floor's zones
            // carve their own walls away, so a rack that insisted on a zone
            // cell in front of a solid wall would almost never find a spot.
            guard !nearSpawn(map, f.cellX, f.cellZ, 4) else { continue }
            guard rng.nextUnit() < 0.045 else { continue }

            let depth = 0.95
            for t in [0.4, f.span - 0.4] {
                for out in [0.08, depth] {
                    let p = facePoint(f, t: t, out: out)
                    dark.addBox(originX: Float(p.x), originY: 0, originZ: Float(p.z), yaw: 0,
                                localX: 0, localY: rackHeight / 2, localZ: 0,
                                halfX: 0.05, halfY: rackHeight / 2, halfZ: 0.05)
                }
            }
            let mid = facePoint(f, t: f.span * 0.5, out: (0.08 + depth) / 2)
            let shelf = faceHalf(f, along: f.span * 0.5 - 0.3, thick: (depth - 0.08) / 2)
            for level in 1...3 {
                let y = rackHeight * Float(level) / 3.0
                dark.addBox(originX: Float(mid.x), originY: 0, originZ: Float(mid.z), yaw: 0,
                            localX: 0, localY: y, localZ: 0,
                            halfX: shelf.halfX, halfY: 0.03, halfZ: shelf.halfZ)
            }
            if rng.nextUnit() < 0.6 {
                let level = 1 + rng.nextInt(2)
                let y = rackHeight * Float(level) / 3.0
                bright.addBox(originX: Float(mid.x), originY: 0, originZ: Float(mid.z), yaw: 0,
                              localX: 0, localY: y + 0.35, localZ: 0,
                              halfX: min(shelf.halfX, 0.42), halfY: 0.33,
                              halfZ: min(shelf.halfZ, 0.42))
            }
            racks += 1
        }

        // Pendant lamps: the web build's cord, shade and bulb, now as real
        // round geometry rather than a billboard.
        var lamps = 0
        for f in map.fixtures {
            guard lamps < 200 else { break }
            let x = Float(map.cellWorldX(f.cellX)), z = Float(map.cellWorldZ(f.cellZ))
            dark.addCylinder(originX: x, originY: 0, originZ: z,
                             localX: 0, localY: wh - 0.55, localZ: 0,
                             radius: 0.016, halfLength: 0.55,
                             axis: .y, segments: 6, capped: false)
            dark.addCylinder(originX: x, originY: 0, originZ: z,
                             localX: 0, localY: wh - 1.18, localZ: 0,
                             radius: 0.40, halfLength: 0.15,
                             axis: .y, segments: 8, capped: true)
            bright.addSphere(originX: x, originY: 0, originZ: z,
                             localX: 0, localY: wh - 1.36, localZ: 0,
                             radius: 0.10, segments: 6, rings: 4)
            lamps += 1
        }
    }

    // MARK: Pipes

    /// Level 2: pipework. A fat run at head height and a thin one at knee
    /// height down the dressed walls, plus ceiling crossings, hanger straps,
    /// the occasional valve, and caged bulbs.
    ///
    /// The web build puts four runs on nearly every wall. This floor has some
    /// 2,600 wall faces, so four runs each would be six figures of triangles in
    /// a single static buffer; the probabilities are turned down and the counts
    /// capped instead. What matters is that a corridor never reads as a bare
    /// tube, and at these rates it does not.
    private static func pipes(map: GameMap, rng: inout Mulberry32,
                              dark: inout MeshBuilder, bright: inout MeshBuilder) {
        let g = map.grid
        let cs = map.spec.cellSize
        let wh = Float(map.spec.wallHeight)
        let faces = wallFaces(map: map)

        var valves = 0
        for f in faces {
            let axis = runAxis(f)
            let half = Float(f.span / 2)

            if rng.nextUnit() < 0.13 {
                let p = facePoint(f, t: f.span * 0.5, out: 0.16)
                let y = wh - 0.55
                // Open-ended: consecutive segments butt into each other, so the
                // caps would never be seen and cost as much as the tube.
                bright.addCylinder(originX: Float(p.x), originY: 0, originZ: Float(p.z),
                                   localX: 0, localY: y, localZ: 0,
                                   radius: 0.12, halfLength: half,
                                   axis: axis, segments: 8, capped: false)
                if rng.nextUnit() < 0.35 {
                    let s = facePoint(f, t: f.span * 0.5, out: 0.08)
                    let strap = faceHalf(f, along: 0.05, thick: 0.10)
                    dark.addBox(originX: Float(s.x), originY: 0, originZ: Float(s.z), yaw: 0,
                                localX: 0, localY: y, localZ: 0,
                                halfX: strap.halfX, halfY: 0.17, halfZ: strap.halfZ)
                }
                if valves < 18, rng.nextUnit() < 0.10 {
                    // A handwheel standing off the pipe, on the axis that points
                    // away from the wall.
                    let stemAxis: MeshBuilder.Axis = f.alongX ? .z : .x
                    let v = facePoint(f, t: f.span * 0.5, out: 0.30)
                    dark.addTorus(originX: Float(v.x), originY: 0, originZ: Float(v.z),
                                  localX: 0, localY: y, localZ: 0,
                                  majorRadius: 0.16, minorRadius: 0.030,
                                  axis: stemAxis, majorSegments: 8, minorSegments: 4)
                    let stem = facePoint(f, t: f.span * 0.5, out: 0.23)
                    dark.addCylinder(originX: Float(stem.x), originY: 0, originZ: Float(stem.z),
                                     localX: 0, localY: y, localZ: 0,
                                     radius: 0.030, halfLength: 0.07,
                                     axis: stemAxis, segments: 6, capped: false)
                    valves += 1
                }
            }
            if rng.nextUnit() < 0.08 {
                let p = facePoint(f, t: f.span * 0.5, out: 0.14)
                bright.addCylinder(originX: Float(p.x), originY: 0, originZ: Float(p.z),
                                   localX: 0, localY: 0.5, localZ: 0,
                                   radius: 0.085, halfLength: half,
                                   axis: axis, segments: 8, capped: false)
            }
        }

        // Ceiling crossings, so looking up is not looking at a blank slab.
        var crossings = 0
        for z in 1..<(g - 1) {
            for x in 1..<(g - 1) {
                guard crossings < 140 else { break }
                guard map.pillarMask[x + z * g] == 0 else { continue }
                guard rng.nextUnit() < 0.09 else { continue }
                let wx = Float(map.cellWorldX(x)), wz = Float(map.cellWorldZ(z))
                let axis: MeshBuilder.Axis = rng.nextUnit() < 0.5 ? .x : .z
                let y = wh - 0.18
                bright.addCylinder(originX: wx, originY: 0, originZ: wz,
                                   localX: 0, localY: y, localZ: 0,
                                   radius: 0.11, halfLength: Float(cs / 2),
                                   axis: axis, segments: 8, capped: false)
                if rng.nextUnit() < 0.4 {
                    dark.addBox(originX: wx, originY: 0, originZ: wz, yaw: 0,
                                localX: 0, localY: y + 0.085, localZ: 0,
                                halfX: 0.14, halfY: 0.09, halfZ: 0.14)
                }
                crossings += 1
            }
        }

        // Caged bulbs on the ceiling. Every fixture gets one — a ceiling where
        // half the lamps are missing geometry reads as a bug, not as decay —
        // so each is kept to the cheapest shape that still reads as caged.
        var cages = 0
        for f in map.fixtures {
            guard cages < 300 else { break }
            let x = Float(map.cellWorldX(f.cellX)), z = Float(map.cellWorldZ(f.cellZ))
            dark.addCylinder(originX: x, originY: 0, originZ: z,
                             localX: 0, localY: wh - 0.09, localZ: 0,
                             radius: 0.05, halfLength: 0.10,
                             axis: .y, segments: 5, capped: true)
            bright.addSphere(originX: x, originY: 0, originZ: z,
                             localX: 0, localY: wh - 0.20, localZ: 0,
                             radius: 0.075, heightRadius: 0.09, segments: 6, rings: 3)
            dark.addTorus(originX: x, originY: 0, originZ: z,
                          localX: 0, localY: wh - 0.20, localZ: 0,
                          majorRadius: 0.11, minorRadius: 0.012,
                          axis: .x, majorSegments: 6, minorSegments: 3)
            cages += 1
        }
    }

    // MARK: Pool

    /// One cell-long boundary between a raised deck cell and a water cell.
    /// `deckSign` says which way the deck lies from the boundary line.
    private struct PoolEdge {
        let alongX: Bool
        let a0: Double, fixed: Double, deckSign: Double

        /// A point `t` metres along the edge and `into` metres onto the deck.
        func point(t: Double, into: Double) -> (x: Double, z: Double) {
            let off = fixed + deckSign * into
            return alongX ? (x: a0 + t, z: off) : (x: off, z: a0 + t)
        }
        /// Half-extents for a box `along` metres long and `thick` metres deep.
        func half(along: Double, thick: Double) -> (halfX: Float, halfZ: Float) {
            alongX ? (halfX: Float(along), halfZ: Float(thick))
                   : (halfX: Float(thick), halfZ: Float(along))
        }
    }

    /// Level 37: the poolside. Coping along every water edge, the drop from the
    /// platform down to the water, handrails, ladders, lane markers and domed
    /// ceiling lights.
    ///
    /// The pool edge is where this floor's silhouette lives. The platform
    /// heights already exist in `groundHeight` and the water sheet already
    /// stops at them, but nothing draws the step itself — so without this the
    /// edge is something you discover by walking off it. `LevelGeometry` is
    /// pinned byte-exact and cannot gain the platform decks, so the drop is
    /// emitted here, set back from the boundary so a real deck could still be
    /// laid over it later without z-fighting.
    private static func pool(map: GameMap, rng: inout Mulberry32,
                             dark: inout MeshBuilder, bright: inout MeshBuilder) {
        let g = map.grid
        let cs = map.spec.cellSize
        let wh = Float(map.spec.wallHeight)
        let plat = Float(GameMap.platformHeight)

        // Every deck cell that touches water contributes one edge segment.
        var edges: [PoolEdge] = []
        edges.reserveCapacity(512)
        for z in 0..<g {
            for x in 0..<g {
                guard map.zoneMask[x + z * g] == 0 else { continue }
                let xa = (Double(x) - Double(g) / 2) * cs
                let za = (Double(z) - Double(g) / 2) * cs
                if z > 0, map.zoneMask[x + (z - 1) * g] != 0 {
                    edges.append(PoolEdge(alongX: true, a0: xa, fixed: za, deckSign: 1))
                }
                if z < g - 1, map.zoneMask[x + (z + 1) * g] != 0 {
                    edges.append(PoolEdge(alongX: true, a0: xa, fixed: za + cs, deckSign: -1))
                }
                if x > 0, map.zoneMask[x - 1 + z * g] != 0 {
                    edges.append(PoolEdge(alongX: false, a0: za, fixed: xa, deckSign: 1))
                }
                if x < g - 1, map.zoneMask[x + 1 + z * g] != 0 {
                    edges.append(PoolEdge(alongX: false, a0: za, fixed: xa + cs, deckSign: -1))
                }
            }
        }

        var coping = 0
        var rails = 0
        var ladders = 0
        for e in edges {
            guard coping < 320 else { break }
            let axis: MeshBuilder.Axis = e.alongX ? .x : .z

            // The wall of the platform, from just above the pool floor up to
            // the deck. Set back from the boundary line so it is never
            // coplanar with anything else on it.
            let wall = e.point(t: cs / 2, into: 0.09)
            let wallHalf = e.half(along: cs / 2, thick: 0.09)
            bright.addBox(originX: Float(wall.x), originY: 0, originZ: Float(wall.z), yaw: 0,
                          localX: 0, localY: plat * 0.5 + 0.002,
                          localZ: 0,
                          halfX: wallHalf.halfX, halfY: plat * 0.5 - 0.002,
                          halfZ: wallHalf.halfZ)

            // The coping lip, standing on the deck edge.
            let lip = e.point(t: cs / 2, into: 0.145)
            let lipHalf = e.half(along: cs / 2, thick: 0.195)
            bright.addBox(originX: Float(lip.x), originY: 0, originZ: Float(lip.z), yaw: 0,
                          localX: 0, localY: plat + 0.047, localZ: 0,
                          halfX: lipHalf.halfX, halfY: 0.045, halfZ: lipHalf.halfZ)
            coping += 1

            if rails < 40, rng.nextUnit() < 0.22 {
                let railY = plat + 0.95
                let mid = e.point(t: cs / 2, into: 0.55)
                bright.addCylinder(originX: Float(mid.x), originY: 0, originZ: Float(mid.z),
                                   localX: 0, localY: railY, localZ: 0,
                                   radius: 0.035, halfLength: Float(cs / 2 - 0.3),
                                   axis: axis, segments: 8, capped: true)
                for t in [0.35, cs - 0.35] {
                    let post = e.point(t: t, into: 0.55)
                    bright.addCylinder(originX: Float(post.x), originY: 0, originZ: Float(post.z),
                                       localX: 0, localY: plat + 0.478, localZ: 0,
                                       radius: 0.030, halfLength: 0.472,
                                       axis: .y, segments: 8, capped: true)
                }
                rails += 1
            } else if ladders < 8, rng.nextUnit() < 0.06 {
                // Two stiles standing in the water, four rungs between them.
                for side in [-1.0, 1.0] {
                    let stile = e.point(t: cs / 2 + side * 0.24, into: -0.22)
                    bright.addCylinder(originX: Float(stile.x), originY: 0, originZ: Float(stile.z),
                                       localX: 0, localY: 0.72, localZ: 0,
                                       radius: 0.030, halfLength: 0.68,
                                       axis: .y, segments: 8, capped: true)
                }
                let rung = e.point(t: cs / 2, into: -0.22)
                for k in 0..<4 {
                    bright.addCylinder(originX: Float(rung.x), originY: 0, originZ: Float(rung.z),
                                       localX: 0, localY: 0.22 + Float(k) * 0.28, localZ: 0,
                                       radius: 0.020, halfLength: 0.24,
                                       axis: axis, segments: 6, capped: true)
                }
                ladders += 1
            }
        }

        // Lane markers on the pool floor: dark tile lines under the water.
        var lanes = 0
        for z in 0..<g {
            for x in 0..<g {
                guard lanes < 90 else { break }
                guard map.zoneMask[x + z * g] != 0, x % 3 == 0 else { continue }
                let wx = Float(map.cellWorldX(x)), wz = Float(map.cellWorldZ(z))
                dark.addBox(originX: wx, originY: 0, originZ: wz, yaw: 0,
                            localX: 0, localY: 0.016, localZ: 0,
                            halfX: 0.10, halfY: 0.014, halfZ: Float(cs / 2))
                lanes += 1
            }
        }

        // Domed ceiling lights, matching the web build's hemisphere fixture.
        // Every fixture gets one, so the dome is kept to two rings — at 0.55m
        // across on a 3.4m ceiling the facets do not read anyway.
        var domes = 0
        for f in map.fixtures {
            guard domes < 400 else { break }
            let x = Float(map.cellWorldX(f.cellX)), z = Float(map.cellWorldZ(f.cellZ))
            bright.addHemisphere(originX: x, originY: 0, originZ: z,
                                 localX: 0, localY: wh - 0.01, localZ: 0,
                                 radius: 0.55, heightRadius: 0.30,
                                 axis: .y, pointingUp: false, segments: 10, rings: 2)
            domes += 1
        }
    }
}
