import Foundation

/// The things on a floor worth walking to: the tapes you came for and the door
/// out. Ported from `buildTapes` / `placeExitFar` / `relocateExit` / the tape
/// and door branches of `findInteract` in the web build.
///
/// Placement is deterministic from the level seed, but it is *not* byte-equal
/// to the web build: there, tapes draw from `lrng`, the same stream the map
/// generator has already been consuming, so matching would mean replicating
/// every intervening draw. This uses a dedicated stream off the same seed. The
/// rules that matter — how far out, how spread, how the door moves — are ported
/// exactly.
public enum Objectives {

    /// Tapes never spawn nearer than this many cells from spawn, so a floor
    /// can't hand you the level in the first room.
    public static let minSpawnDistance: Int16 = 7
    /// Placement jitter inside a cell, in metres.
    public static let jitter = 2.0

    /// Reach for `[E]` / USE, and how far off-centre you may be looking.
    public static let tapeReach = 2.3
    public static let doorReach = 2.7
    public static let facingDot = 0.45
    public static let doorFacingDot = 0.35
    /// Inside this distance, facing stops mattering — you are on top of it.
    public static let pointBlank = 1.0
    public static let doorPointBlank = 1.4

    /// The door announces itself at this range even if you have no tapes.
    public static let revealDistance = 9.0
    /// How close you must still be when the door finishes swinging.
    public static let throughDoorDistance = 1.8
    /// Seconds the door takes to open.
    public static let doorOpenTime = 0.9

    public struct Tape: Sendable, Equatable {
        public let index: Int          // 0-based, within the floor
        public let x: Double
        public let z: Double
        public let yaw: Double
        public var found = false
    }

    public struct Exit: Sendable, Equatable {
        public var x: Double
        public var z: Double
        /// Marked once seen, or once the tapes drag it to you.
        public var revealed = false
        public var opening = false
        public var openTime = 0.0

        public var isOpen: Bool { opening && openTime >= Objectives.doorOpenTime * 0.5 }
    }

    /// What `[E]` would act on right now.
    public enum Interaction: Equatable {
        case tape(index: Int)
        case door

        public var label: String {
            switch self {
            case .tape: return "TAKE TAPE"
            case .door: return "OPEN DOOR"
            }
        }
    }

    // MARK: - Placement

    /// Scatters `count` tapes around the floor, one per angular sector so they
    /// cannot all end up behind you, each at least `minSpawnDistance` cells out.
    public static func placeTapes(map: GameMap, count: Int, rng: inout Mulberry32) -> [Tape] {
        guard count > 0 else { return [] }
        let grid = map.grid
        let dist = map.distanceField(fromX: map.spawnX, z: map.spawnZ)

        // Bucket every eligible cell by its bearing from spawn.
        var buckets = [[(x: Int, z: Int, d: Int16)]](repeating: [], count: count)
        for z in 1..<(grid - 1) {
            for x in 1..<(grid - 1) {
                let d = dist[x + z * grid]
                if d < minSpawnDistance { continue }
                if map.pillarMask[x + z * grid] != 0 { continue }
                // Poolrooms: never in the water, you would never see it.
                if map.spec.theme == .pool && map.zoneMask[x + z * grid] != 0 { continue }
                let angle = atan2(Double(z - map.spawnZ), Double(x - map.spawnX))
                let bi = min(count - 1, Int((angle + .pi) / (2 * .pi) * Double(count)))
                buckets[bi].append((x, z, d))
            }
        }

        var tapes: [Tape] = []
        for i in 0..<count {
            // An empty sector borrows from its neighbour rather than dropping
            // a tape — a floor must always carry its full count.
            var pool = buckets[i].isEmpty ? buckets[(i + 1) % count] : buckets[i]
            if pool.isEmpty {
                pool = [(min(grid - 2, map.spawnX + 4 + i), map.spawnZ, 8)]
            }
            pool.sort { $0.d < $1.d }
            // Biased into the middle-to-far part of the sector: far enough to
            // be a trip, not so far it is the opposite corner every time.
            let t = 0.35 + rng.nextUnit() * 0.5
            let pick = pool[min(pool.count - 1, Int(Double(pool.count) * t))]
            let x = map.cellWorldX(pick.x) + (rng.nextUnit() - 0.5) * jitter
            let z = map.cellWorldZ(pick.z) + (rng.nextUnit() - 0.5) * jitter
            let yaw = rng.nextUnit() * 6.28
            tapes.append(Tape(index: i, x: x, z: z, yaw: yaw))
        }
        return tapes
    }

    /// The door starts at the single furthest reachable cell from spawn — the
    /// long way round is the level.
    public static func placeExitFar(map: GameMap) -> Exit {
        let grid = map.grid
        let dist = map.distanceField(fromX: map.spawnX, z: map.spawnZ)
        var best = (x: grid - 3, z: grid - 3)
        var bestD: Int16 = -1
        for z in 1..<(grid - 1) {
            for x in 1..<(grid - 1) {
                let d = dist[x + z * grid]
                if d > bestD && map.pillarMask[x + z * grid] == 0 {
                    bestD = d
                    best = (x, z)
                }
            }
        }
        return Exit(x: map.cellWorldX(best.x), z: map.cellWorldZ(best.z))
    }

    /// Once the last tape is recovered the door tears through a wall *near the
    /// player* — 2 to 4 rooms out. It is the reward for finishing the floor,
    /// so it must be close, but not so close it lands in your lap.
    public static func relocatedExit(map: GameMap, playerX: Double, playerZ: Double,
                                     rng: inout Mulberry32) -> (x: Double, z: Double)? {
        let grid = map.grid
        let dist = map.distanceField(fromX: map.worldToCellX(playerX),
                                     z: map.worldToCellZ(playerZ))
        var candidates: [(Int, Int)] = []
        for z in 1..<(grid - 1) {
            for x in 1..<(grid - 1) {
                let d = dist[x + z * grid]
                if d >= 2 && d <= 4 && map.pillarMask[x + z * grid] == 0 {
                    candidates.append((x, z))
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        let c = candidates[rng.nextInt(candidates.count)]
        return (map.cellWorldX(c.0), map.cellWorldZ(c.1))
    }

    // MARK: - Interaction

    /// Picks what `[E]` should act on: nearest thing in reach that you are
    /// broadly facing, closest wins. Facing is ignored point-blank so you can
    /// never be standing on a tape unable to take it.
    public static func findInteraction(tapes: [Tape], exit: Exit?,
                                       playerX: Double, playerZ: Double,
                                       forwardX: Double, forwardZ: Double) -> Interaction? {
        var best: Interaction?
        var bestScore = 0.0

        for tape in tapes where !tape.found {
            let dx = tape.x - playerX, dz = tape.z - playerZ
            let d = (dx * dx + dz * dz).squareRoot()
            if d > tapeReach { continue }
            let dot = (forwardX * dx + forwardZ * dz) / max(0.001, d)
            if dot < facingDot && d > pointBlank { continue }
            let score = tapeReach - d
            if score > bestScore { bestScore = score; best = .tape(index: tape.index) }
        }

        if let exit, !exit.opening {
            let dx = exit.x - playerX, dz = exit.z - playerZ
            let d = (dx * dx + dz * dz).squareRoot()
            if d < doorReach {
                let dot = (forwardX * dx + forwardZ * dz) / max(0.001, d)
                if dot > doorFacingDot || d < doorPointBlank {
                    // Scored above tapes on purpose: standing in the doorway
                    // with a tape at your feet, you meant the door.
                    let score = 3.2 - d
                    if score > bestScore { bestScore = score; best = .door }
                }
            }
        }
        return best
    }
}
