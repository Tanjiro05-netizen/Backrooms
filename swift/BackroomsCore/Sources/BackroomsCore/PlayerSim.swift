import Foundation

/// Deterministic player movement, collision and stamina — the port of the web
/// build's `updatePlayer` movement core and `collide()`. Battery/health/nerve
/// are excluded here: they depend on entity, lighting and director state that
/// port in later phases. This models exactly the part that decides *where the
/// player ends up* given input.
///
/// Note on precision: unlike the map and geometry (integer-exact), movement
/// uses sin/cos/exp/sqrt, whose last bit can differ between JS and Swift
/// libms. Trace fixtures therefore assert a tight numeric tolerance, not a
/// byte hash — a real algorithm bug diverges by orders of magnitude, while
/// libm noise stays sub-nanometre.
public struct PlayerSim {
    public struct Input: Sendable {
        public var moveX: Double   // -1 (A/left) .. +1 (D/right)
        public var moveZ: Double   // -1 (W/forward) .. +1 (S/back)
        public var run: Bool
        public var yaw: Double     // look heading, set by camera/gyro/drag
        public init(moveX: Double = 0, moveZ: Double = 0, run: Bool = false, yaw: Double) {
            self.moveX = moveX; self.moveZ = moveZ; self.run = run; self.yaw = yaw
        }
    }

    // Tuning constants, transcribed from the web build.
    public static let eyeHeight = 1.62
    static let walkSpeed = 3.1
    static let sprintSpeed = 5.4
    static let waterFactor = 0.62
    static let radius = 0.33
    static let staminaDrain = 16.0
    static let staminaRegen = 11.0

    public private(set) var x: Double
    public private(set) var z: Double
    public private(set) var vx = 0.0
    public private(set) var vz = 0.0
    public private(set) var yaw: Double
    public private(set) var stamina = 100.0
    public private(set) var moveAmount = 0.0
    public private(set) var groundY: Double

    private let map: GameMap
    private let colliders: [Int: [LevelGeometry.ColliderRect]]
    private let limit: Double

    public init(map: GameMap, colliders: [Int: [LevelGeometry.ColliderRect]]) {
        self.map = map
        self.colliders = colliders
        self.x = map.cellWorldX(map.spawnX)
        self.z = map.cellWorldZ(map.spawnZ)
        self.yaw = -Double.pi / 2
        self.groundY = map.groundHeight(atX: x, z: z)
        self.limit = Double(map.grid) * map.spec.cellSize / 2 - 0.45
    }

    /// One movement tick. Mirrors `updatePlayer`'s movement + `collide()`.
    public mutating func step(dt: Double, input: Input) {
        yaw = input.yaw
        var mx = input.moveX, mz = input.moveZ
        let il = (mx * mx + mz * mz).squareRoot()
        if il > 1 { mx /= il; mz /= il }

        let sprint = input.run && stamina > 4 && il > 0.1
        var speed = sprint ? PlayerSim.sprintSpeed : PlayerSim.walkSpeed
        let inWater = (map.spec.theme == .pool && groundY < 0.25)
        if inWater { speed *= PlayerSim.waterFactor }

        let s = sin(yaw), c = cos(yaw)
        let fwdX = -s, fwdZ = -c, rgtX = c, rgtZ = -s
        let wishX = (fwdX * (-mz) + rgtX * mx) * speed
        let wishZ = (fwdZ * (-mz) + rgtZ * mx) * speed
        let k = 1 - exp(-10 * dt)
        vx += (wishX - vx) * k
        vz += (wishZ - vz) * k
        x += vx * dt
        z += vz * dt
        collide()

        let gT = map.groundHeight(atX: x, z: z)
        groundY += (gT - groundY) * min(1, dt * 9)
        let spd = (vx * vx + vz * vz).squareRoot()
        moveAmount = spd
        if sprint && spd > 0.5 { stamina = max(0, stamina - dt * PlayerSim.staminaDrain) }
        else { stamina = min(100, stamina + dt * PlayerSim.staminaRegen) }
    }

    private mutating func collide() {
        let r = PlayerSim.radius
        let cx = map.worldToCellX(x), cz = map.worldToCellZ(z)
        for _ in 0..<2 {
            for zc in (cz - 1)...(cz + 1) {
                for xc in (cx - 1)...(cx + 1) {
                    guard let bucket = colliders[xc + zc * map.grid] else { continue }
                    for a in bucket {
                        let nx = max(a.x0, min(x, a.x1))
                        let nz = max(a.z0, min(z, a.z1))
                        let dx = x - nx, dz = z - nz, d2 = dx * dx + dz * dz
                        if d2 < r * r {
                            if d2 < 1e-9 {
                                let pL = x - (a.x0 - r), pR = (a.x1 + r) - x
                                let pU = z - (a.z0 - r), pD = (a.z1 + r) - z
                                let m = min(pL, pR, pU, pD)
                                if m == pL { x = a.x0 - r }
                                else if m == pR { x = a.x1 + r }
                                else if m == pU { z = a.z0 - r }
                                else { z = a.z1 + r }
                            } else {
                                let d = d2.squareRoot(), p = (r - d) / d
                                x += dx * p; z += dz * p
                            }
                        }
                    }
                }
            }
        }
        x = max(-limit, min(limit, x))
        z = max(-limit, min(limit, z))
    }
}
