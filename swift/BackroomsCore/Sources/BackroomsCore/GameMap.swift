import Foundation

/// A generated floor: wall edges, zones, pillars and fixtures — the direct
/// Swift equivalent of the web build's `vWallA/hWallA/zoneMask/pillarMask`.
///
/// Wall values: 0 = open, 1 = solid wall, 2 = doorway.
/// `vWalls` is indexed `x + z*(grid+1)` (vertical edges, x in 0...grid);
/// `hWalls` is indexed `x + z*grid` (horizontal edges, z in 0...grid).
public struct GameMap: Sendable {
    public let spec: LevelSpec
    public var grid: Int { spec.grid }
    public private(set) var vWalls: [UInt8]
    public private(set) var hWalls: [UInt8]
    public private(set) var zoneMask: [UInt8]
    public private(set) var pillarMask: [UInt8]
    public private(set) var fixtures: [Fixture]
    public let spawnX: Int
    public let spawnZ: Int

    public struct Fixture: Sendable, Equatable {
        public let cellX: Int
        public let cellZ: Int
        public let flicker: Bool
    }

    public func vWall(_ x: Int, _ z: Int) -> UInt8 { vWalls[x + z * (grid + 1)] }
    public func hWall(_ x: Int, _ z: Int) -> UInt8 { hWalls[x + z * grid] }

    /// World-space centre of a cell (matches `cellWX/cellWZ`).
    public func cellWorldX(_ cx: Int) -> Double { (Double(cx) - Double(grid) / 2 + 0.5) * spec.cellSize }
    public func cellWorldZ(_ cz: Int) -> Double { (Double(cz) - Double(grid) / 2 + 0.5) * spec.cellSize }
    public func worldToCellX(_ wx: Double) -> Int { Int((wx / spec.cellSize + Double(grid) / 2).rounded(.down)) }
    public func worldToCellZ(_ wz: Double) -> Int { Int((wz / spec.cellSize + Double(grid) / 2).rounded(.down)) }

    /// Can an entity step from (x,z) to the adjacent (nx,nz)? Port of `passable`.
    public func passable(_ x: Int, _ z: Int, _ nx: Int, _ nz: Int) -> Bool {
        if nx < 0 || nz < 0 || nx >= grid || nz >= grid { return false }
        if pillarMask[nx + nz * grid] != 0 { return false }
        if nx == x + 1 { return vWall(x + 1, z) != 1 }
        if nx == x - 1 { return vWall(x, z) != 1 }
        if nz == z + 1 { return hWall(x, z + 1) != 1 }
        if nz == z - 1 { return hWall(x, z) != 1 }
        return false
    }

    /// Breadth-first distance field from a cell. Port of `bfsFrom`; -1 = unreachable.
    public func distanceField(fromX sx: Int, z sz: Int) -> [Int16] {
        var dist = [Int16](repeating: -1, count: grid * grid)
        var queue = [sx + sz * grid]
        dist[queue[0]] = 0
        var head = 0
        while head < queue.count {
            let cIdx = queue[head]; head += 1
            let x = cIdx % grid, z = cIdx / grid
            let d = dist[cIdx]
            if passable(x, z, x + 1, z) && dist[cIdx + 1] < 0 { dist[cIdx + 1] = d + 1; queue.append(cIdx + 1) }
            if passable(x, z, x - 1, z) && dist[cIdx - 1] < 0 { dist[cIdx - 1] = d + 1; queue.append(cIdx - 1) }
            if passable(x, z, x, z + 1) && dist[cIdx + grid] < 0 { dist[cIdx + grid] = d + 1; queue.append(cIdx + grid) }
            if passable(x, z, x, z - 1) && dist[cIdx - grid] < 0 { dist[cIdx - grid] = d + 1; queue.append(cIdx - grid) }
        }
        return dist
    }

    /// Grid-DDA line of sight between two world points. Port of `losClear`.
    public func lineOfSightClear(ax: Double, az: Double, bx: Double, bz: Double) -> Bool {
        let g = Double(grid)
        let cx = ax / spec.cellSize + g / 2, cz = az / spec.cellSize + g / 2
        let tx = bx / spec.cellSize + g / 2, tz = bz / spec.cellSize + g / 2
        var ix = Int(cx.rounded(.down)), iz = Int(cz.rounded(.down))
        let dx = tx - cx, dz = tz - cz
        let stepX = dx > 0 ? 1 : -1, stepZ = dz > 0 ? 1 : -1
        let tDX = abs(1 / (dx == 0 ? 1e-9 : dx)), tDZ = abs(1 / (dz == 0 ? 1e-9 : dz))
        var tMaxX = (stepX > 0 ? (Double(ix) + 1 - cx) : (cx - Double(ix))) * tDX
        var tMaxZ = (stepZ > 0 ? (Double(iz) + 1 - cz) : (cz - Double(iz))) * tDZ
        let endX = Int(tx.rounded(.down)), endZ = Int(tz.rounded(.down))
        for _ in 0..<110 {
            if ix == endX && iz == endZ { return true }
            if tMaxX < tMaxZ {
                if !passable(ix, iz, ix + stepX, iz) { return false }
                ix += stepX; tMaxX += tDX
            } else {
                if !passable(ix, iz, ix, iz + stepZ) { return false }
                iz += stepZ; tMaxZ += tDZ
            }
        }
        return false
    }

    // MARK: - Generation

    /// Generates the floor exactly as the web build's `generateMap` does,
    /// consuming the PRNG stream in the same order — same seed, same maze.
    public static func generate(spec: LevelSpec, levelIndex: Int) -> GameMap {
        var rng = Mulberry32(seed: LevelSpec.seed(forLevel: levelIndex))
        return generate(spec: spec, rng: &rng)
    }

    public static func generate(spec: LevelSpec, rng: inout Mulberry32) -> GameMap {
        let gw = spec.grid, gh = spec.grid
        var vW = [UInt8](repeating: 0, count: (gw + 1) * gh)
        var hW = [UInt8](repeating: 0, count: gw * (gh + 1))
        var zone = [UInt8](repeating: 0, count: gw * gh)
        var pillar = [UInt8](repeating: 0, count: gw * gh)
        var fixtures: [Fixture] = []
        let spawnX = max(3, Int((Double(gw) * 0.16).rounded()))
        let spawnZ = gh >> 1

        func setV(_ x: Int, _ z: Int, _ v: UInt8) { vW[x + z * (gw + 1)] = v }
        func getV(_ x: Int, _ z: Int) -> UInt8 { vW[x + z * (gw + 1)] }
        func setH(_ x: Int, _ z: Int, _ v: UInt8) { hW[x + z * gw] = v }
        func getH(_ x: Int, _ z: Int) -> UInt8 { hW[x + z * gw] }

        // Border walls.
        for z in 0..<gh { setV(0, z, 1); setV(gw, z, 1) }
        for x in 0..<gw { setH(x, 0, 1); setH(x, gh, 1) }
        // Random interior walls.
        for z in 0..<gh { for x in 1..<gw { if rng.nextUnit() < spec.wallP { setV(x, z, 1) } } }
        for z in 1..<gh { for x in 0..<gw { if rng.nextUnit() < spec.wallP { setH(x, z, 1) } } }
        // Carved open zones (+ optional pillar lattice).
        for _ in 0..<spec.zones {
            let w = spec.zoneMin + rng.nextInt(spec.zoneMax - spec.zoneMin + 1)
            let h = spec.zoneMin + rng.nextInt(spec.zoneMax - spec.zoneMin + 1)
            let x0 = 1 + rng.nextInt(gw - w - 2)
            let z0 = 1 + rng.nextInt(gh - h - 2)
            for z in z0..<(z0 + h) { for x in x0..<(x0 + w) {
                zone[x + z * gw] = 1
                if x > x0 { setV(x, z, 0) }
                if z > z0 { setH(x, z, 0) }
            } }
            if spec.pillarP > 0 {
                for z in z0..<(z0 + h) { for x in x0..<(x0 + w) {
                    if (x - x0) % 2 == 1 && (z - z0) % 2 == 1 && rng.nextUnit() < spec.pillarP {
                        pillar[x + z * gw] = 1
                    }
                } }
            }
        }
        // Doorways.
        for z in 0..<gh { for x in 1..<gw { if getV(x, z) == 1 && rng.nextUnit() < spec.doorP { setV(x, z, 2) } } }
        for z in 1..<gh { for x in 0..<gw { if getH(x, z) == 1 && rng.nextUnit() < spec.doorP { setH(x, z, 2) } } }
        // Clear the spawn pocket.
        for z in (spawnZ - 1)...(spawnZ + 1) { for x in (spawnX - 1)...(spawnX + 1) {
            pillar[x + z * gw] = 0
            zone[x + z * gw] = 0
            if x > spawnX - 1 { setV(x, z, 0) }
            if z > spawnZ - 1 { setH(x, z, 0) }
        } }

        // Connectivity: repeatedly punch doorways toward unreachable pockets.
        var probe = GameMap(spec: spec, vWalls: vW, hWalls: hW, zoneMask: zone,
                            pillarMask: pillar, fixtures: [], spawnX: spawnX, spawnZ: spawnZ)
        for _ in 0..<900 {
            let dist = probe.distanceField(fromX: spawnX, z: spawnZ)
            var frontier: [(isV: Bool, x: Int, z: Int)] = []
            for z in 0..<gh { for x in 0..<gw {
                if dist[x + z * gw] < 0 { continue }
                if x + 1 < gw && dist[x + 1 + z * gw] < 0 && pillar[x + 1 + z * gw] == 0 && getV(x + 1, z) == 1 {
                    frontier.append((true, x + 1, z))
                }
                if z + 1 < gh && dist[x + (z + 1) * gw] < 0 && pillar[x + (z + 1) * gw] == 0 && getH(x, z + 1) == 1 {
                    frontier.append((false, x, z + 1))
                }
            } }
            if frontier.isEmpty { break }
            let f = frontier[rng.nextInt(frontier.count)]
            if f.isV { setV(f.x, f.z, 2) } else { setH(f.x, f.z, 2) }
            probe = GameMap(spec: spec, vWalls: vW, hWalls: hW, zoneMask: zone,
                            pillarMask: pillar, fixtures: [], spawnX: spawnX, spawnZ: spawnZ)
        }

        // Ceiling fixtures on a lattice.
        for z in 0..<gh { for x in 0..<gw {
            if x % spec.fixEvery == 0 && z % spec.fixEvery == 0 && rng.nextUnit() < spec.fixP {
                let r = rng.nextUnit()
                if r < spec.brokenP { continue }
                fixtures.append(Fixture(cellX: x, cellZ: z, flicker: r < spec.brokenP + spec.flickP))
            }
        } }

        return GameMap(spec: spec, vWalls: vW, hWalls: hW, zoneMask: zone,
                       pillarMask: pillar, fixtures: fixtures, spawnX: spawnX, spawnZ: spawnZ)
    }

    private init(spec: LevelSpec, vWalls: [UInt8], hWalls: [UInt8], zoneMask: [UInt8],
                 pillarMask: [UInt8], fixtures: [Fixture], spawnX: Int, spawnZ: Int) {
        self.spec = spec
        self.vWalls = vWalls
        self.hWalls = hWalls
        self.zoneMask = zoneMask
        self.pillarMask = pillarMask
        self.fixtures = fixtures
        self.spawnX = spawnX
        self.spawnZ = spawnZ
    }
}
