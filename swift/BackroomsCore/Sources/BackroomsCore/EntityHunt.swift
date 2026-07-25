import Foundation

/// The hunting entity's chase navigation — the port of the `state==='hunt'`
/// branch of the web build's `updateEntity`. The entity re-runs a BFS distance
/// field from the player every 0.55s, greedily steps toward the lower-distance
/// neighbour cell (or straight at the player when close), and integrates
/// movement at a speed that scales with difficulty, tapes collected and (for
/// the crawler) a random burst.
///
/// The crawler's burst timing is the sole source of randomness; it draws from
/// an injected `Mulberry32` so tests are deterministic. As with `PlayerSim`,
/// movement uses hypot/division, so trace fixtures assert a tolerance rather
/// than a byte hash.
public struct EntityHunt {
    // Combat/hunt tuning constants from the web build.
    static let huntAggro = 1.28
    static let huntMax = 5.15
    static let atkReach = 0.45
    static let cellSizeCloseFactor = 0.9   // `dist < CS*0.9` snaps to the player

    public private(set) var x: Double
    public private(set) var z: Double
    public private(set) var yaw = 0.0
    public private(set) var timer: Double
    public private(set) var speedNow = 0.0
    public private(set) var reachedAttack = false   // entered swipe range this step

    private var repath = 0.0
    private var distField: [Int16] = []
    private var burstDur = 0.0
    private var burstT = 1.5
    private let def: EntityDef
    private let map: GameMap
    private var rng: Mulberry32

    /// `difficulty.speed` — 1.0 on standard, 0.78 on simple.
    public var difficultySpeed = 1.0

    public init(def: EntityDef, map: GameMap, cellX: Int, cellZ: Int,
                difficultyHuntTime: Double = 1.0, rngSeed: UInt32 = 12345) {
        self.def = def
        self.map = map
        self.x = map.cellWorldX(cellX)
        self.z = map.cellWorldZ(cellZ)
        self.timer = def.huntTime * difficultyHuntTime
        self.rng = Mulberry32(seed: rngSeed)
    }

    private func baseSpeed() -> Double {
        if let ws = def.waterSpeed, map.spec.theme == .pool {
            let cx = map.worldToCellX(x), cz = map.worldToCellZ(z)
            if cx >= 0 && cz >= 0 && cx < map.grid && cz < map.grid
                && map.zoneMask[cx + cz * map.grid] != 0 { return ws }
        }
        return def.speed
    }

    /// One hunt tick chasing the given world-space player position.
    /// `tapesFound` feeds the escalating-speed term. Returns false once the
    /// entity should despawn (timer elapsed or player fled beyond 46m).
    @discardableResult
    public mutating func step(dt: Double, playerX: Double, playerZ: Double,
                              tapesFound: Int, attackReady: Bool) -> Bool {
        reachedAttack = false
        timer -= dt
        repath -= dt

        var mult = 1.0
        if let burst = def.burst {
            if burstDur > 0 { burstDur -= dt; mult = burst.mult }
            else {
                burstT -= dt
                if burstT < 0 {
                    burstT = burst.period * (0.7 + rng.nextUnit() * 0.6)
                    burstDur = burst.duration
                }
            }
        }
        speedNow = min(EntityHunt.huntMax,
                       baseSpeed() * difficultySpeed * mult * EntityHunt.huntAggro
                       * (1 + min(0.4, Double(tapesFound) * 0.05)))

        if repath <= 0 {
            distField = map.distanceField(fromX: map.worldToCellX(playerX),
                                          z: map.worldToCellZ(playerZ))
            repath = 0.55
        }

        let cx = map.worldToCellX(x), cz = map.worldToCellZ(z)
        var bx = cx, bz = cz
        var bd = distField[cx + cz * map.grid]
        if bd < 0 { bd = 9999 }
        let nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for (dx, dz) in nb {
            let nx = cx + dx, nz = cz + dz
            if !map.passable(cx, cz, nx, nz) { continue }
            let d = distField[nx + nz * map.grid]
            if d >= 0 && d < bd { bd = d; bx = nx; bz = nz }
        }

        let dxp = playerX - x, dzp = playerZ - z
        let dist = (dxp * dxp + dzp * dzp).squareRoot()
        let tx: Double, tz: Double
        if dist < map.spec.cellSize * EntityHunt.cellSizeCloseFactor || (bx == cx && bz == cz) {
            tx = playerX; tz = playerZ
        } else {
            tx = map.cellWorldX(bx); tz = map.cellWorldZ(bz)
        }
        let ddx = tx - x, ddz = tz - z
        let dl = { let h = (ddx * ddx + ddz * ddz).squareRoot(); return h == 0 ? 1 : h }()
        x += ddx / dl * speedNow * dt
        z += ddz / dl * speedNow * dt
        yaw = atan2(-ddx, -ddz)

        if dist < def.catchR + EntityHunt.atkReach && attackReady {
            reachedAttack = true
            timer = max(timer, 4)
        }
        return !(timer <= 0 || dist > 46)
    }
}
