import Foundation

/// The entity's whole life cycle — the port of `updateEntity` in the web build,
/// including the two branches `EntityHunt` deliberately left out: `idle`, where
/// it is off the map scheduling its next appearance, and `seen`, the sighting.
///
/// The sighting is the part of the game that is actually about being watched.
/// It stands at the far end of a corridor and closes on you, but only while you
/// are not looking — and what happens when you *do* look is per-creature: the
/// smiler waits you out and then simply is not there any more, the hound bolts,
/// the crawler and the drowned keep coming regardless. Turning away long enough
/// lets it jump 30% of the gap to you, but only into cover, so the ground it
/// gains is ground you never see it take.
///
/// ## Randomness
///
/// The web build mixes two sources here: `lrng()` (the seeded level stream) for
/// scheduling and placement, and bare `Math.random()` for the flee angle and
/// the reposition roll. This port seeds both, because an unseeded draw is a
/// system that cannot be tested.
///
/// They are two separate streams on purpose. Reaction draws happen when the
/// *player* turns their head, at times no test can predict; if they shared the
/// scheduling stream, looking away from a hound would silently move where the
/// next sighting appears. That coupling — one subsystem's draw count shifting
/// another's results — has already cost this port a day once.
public struct EntityPresence {

    public enum State: Equatable {
        /// Off the map. Counting down to the next sighting and the next hunt.
        case idle
        /// Standing somewhere in front of you, watching.
        case seen
        /// Coming.
        case hunt
    }

    /// Things worth a sound, a light cue or a line of HUD. Returned from `step`
    /// rather than fired through a delegate so the state machine stays pure and
    /// a test can assert the sequence.
    public enum Event: Equatable {
        /// ~1.4s before a hunt: the lights sag and something exhales.
        case telegraph
        case sighting
        case huntBegan
        /// The hound broke and ran because you caught its eye.
        case fled
        /// You stared the smiler down and it stopped existing.
        case vanished
        /// It closed ground behind cover while you were looking elsewhere.
        case repositioned
        /// Any other end to a sighting — it reached you, or it lost interest.
        case sightingEnded
        case huntEnded
        /// A swipe connected.
        case attack
    }

    // Tuning from the web build, named rather than inline so the numbers can be
    // discussed. Angles are the cosine of the half-angle, matching the dot test.

    /// `lookDot > 0.962` — roughly a 16° cone. Narrow on purpose: it has to be
    /// near the middle of the frame to count as being looked at, not merely
    /// somewhere on screen.
    public static let gazeCos = 0.962
    /// Past this it is too far away to register as observed at all.
    public static let gazeRange = 32.0
    /// How fast a sighting flees once it breaks.
    public static let fleeSpeed = 7.6
    public static let fleeTime = 0.95
    /// The hound needs only a quarter-second of eye contact to bolt.
    public static let fleeGaze = 0.25
    /// The smiler needs you to hold it.
    public static let vanishGaze = 1.15
    /// Gaze decays at twice the rate it builds, so glancing away does not reset
    /// a stare-down outright.
    public static let gazeDecay = 2.0
    /// Look away this long and it may reposition.
    public static let repositionAfter = 2.3
    public static let repositionChance = 0.55
    /// It takes 30% of the remaining gap, and only into somewhere you cannot see.
    public static let repositionFraction = 0.30
    public static let repositionMinDistance = 7.0
    /// Attempts to find a sighting spot before giving up for this cycle.
    static let sightingTries = 60

    // MARK: - Observable state

    public private(set) var state: State = .idle
    /// Position and heading, valid while `state != .idle`.
    public private(set) var x: Double = 0
    public private(set) var z: Double = 0
    public private(set) var yaw: Double = 0
    public var isVisible: Bool { state != .idle }

    /// Seconds until the next hunt and the next sighting attempt. Both only
    /// count down while idle — a hunt does not schedule over itself.
    public private(set) var nextHunt: Double
    public private(set) var nextSight: Double
    /// True once the pre-hunt cue has fired for the upcoming hunt.
    public private(set) var telegraphed = false

    /// Seconds this sighting has left before it loses interest.
    public private(set) var sightingTimer: Double = 0
    /// Accumulated eye contact.
    public private(set) var gaze: Double = 0
    /// Nonzero while it is running away.
    public private(set) var fleeTime: Double = 0
    /// True while the player is looking at it — refreshed every step.
    public private(set) var isObserved = false
    /// Distance the entity has covered, for a walk cycle. Never reset, so a
    /// creature that creeps, vanishes and hunts does not snap mid-stride.
    public private(set) var stride: Double = 0

    /// The chase, live only while `state == .hunt`.
    public private(set) var hunt: EntityHunt?

    public var def: EntityDef { definition }
    public var difficulty = EntityDifficulty.standard

    // MARK: - Private

    private let definition: EntityDef
    private let map: GameMap
    private var fleeDX = 0.0
    private var fleeDZ = 0.0
    /// Seconds since the player last had it in view.
    private var unobservedTime = 0.0
    /// Scheduling and placement: sighting timing and position, hunt timing and
    /// spawn cell.
    private var scheduleRng: Mulberry32
    /// Reactions to the player: flee bearing, reposition roll.
    private var reactRng: Mulberry32
    private let huntSeed: UInt32

    public init(def: EntityDef, map: GameMap, seed: UInt32,
                difficulty: EntityDifficulty = .standard) {
        self.definition = def
        self.map = map
        self.difficulty = difficulty
        self.scheduleRng = Mulberry32(seed: seed &+ 991)
        self.reactRng = Mulberry32(seed: seed &+ 40_961)
        self.huntSeed = seed &+ 7
        // `nextSight:(8+lrng()*8)*diff.sight, nextHunt:def.baseHuntDelay*diff.hunt`
        self.nextHunt = def.baseHuntDelay * difficulty.hunt
        self.nextSight = 0
        self.nextSight = (8 + scheduleRng.nextUnit() * 8) * difficulty.sight
    }

    // MARK: - Step

    /// One fixed step. `forwardX`/`forwardZ` are the camera's horizontal facing,
    /// which is what decides whether the thing is being looked at.
    public mutating func step(dt: Double,
                              playerX: Double, playerZ: Double,
                              forwardX: Double, forwardZ: Double,
                              tapesFound: Int, attackReady: Bool) -> [Event] {
        var events: [Event] = []
        let beforeX = x, beforeZ = z

        switch state {
        case .idle:
            stepIdle(dt: dt, playerX: playerX, playerZ: playerZ,
                     forwardX: forwardX, forwardZ: forwardZ, events: &events)
        case .seen:
            stepSeen(dt: dt, playerX: playerX, playerZ: playerZ,
                     forwardX: forwardX, forwardZ: forwardZ, events: &events)
        case .hunt:
            stepHunt(dt: dt, playerX: playerX, playerZ: playerZ,
                     tapesFound: tapesFound, attackReady: attackReady, events: &events)
        }

        // Stride drives the walk cycle, so it must only count ground the thing
        // actually walked. Every one of these events moves it discontinuously —
        // an appearance, a spawn, a jump behind cover — and folding that jump
        // into the stride would make the legs windmill for a step.
        let teleported = events.contains(.sighting)
            || events.contains(.huntBegan)
            || events.contains(.repositioned)
        if state != .idle && !teleported {
            let dx = x - beforeX, dz = z - beforeZ
            self.stride += (dx * dx + dz * dz).squareRoot()
        }
        return events
    }

    // MARK: - Idle

    private mutating func stepIdle(dt: Double, playerX: Double, playerZ: Double,
                                   forwardX: Double, forwardZ: Double,
                                   events: inout [Event]) {
        isObserved = false
        nextSight -= dt
        nextHunt -= dt

        if nextHunt <= 1.4 && !telegraphed {
            telegraphed = true
            events.append(.telegraph)
        }
        if nextHunt <= 0 {
            startHunt(playerX: playerX, playerZ: playerZ, events: &events)
        } else if nextSight <= 0 {
            trySighting(playerX: playerX, playerZ: playerZ,
                        forwardX: forwardX, forwardZ: forwardZ, events: &events)
            nextSight = (9 + scheduleRng.nextUnit() * 12) * difficulty.sight
        }
    }

    // MARK: - Sighting

    /// Look for somewhere in the player's forward arc that is in the open, in
    /// line of sight, and the right distance away. Up to 60 attempts; if none
    /// of them land — a tight room, a wall in the way — the cycle is simply
    /// skipped and the next one is rescheduled by the caller.
    private mutating func trySighting(playerX: Double, playerZ: Double,
                                      forwardX: Double, forwardZ: Double,
                                      events: inout [Event]) {
        for _ in 0..<EntityPresence.sightingTries {
            // ±1 radian off the player's facing, so it appears in view or just
            // at the edge of it — never behind.
            let ang = (scheduleRng.nextUnit() * 2 - 1) * 1.0
            let reach = definition.sightMin
                + scheduleRng.nextUnit() * (definition.sightMax - definition.sightMin)
            let ca = cos(ang), sa = sin(ang)
            let dirX = forwardX * ca - forwardZ * sa
            let dirZ = forwardX * sa + forwardZ * ca
            let wx = playerX + dirX * reach, wz = playerZ + dirZ * reach
            let cx = map.worldToCellX(wx), cz = map.worldToCellZ(wz)
            if cx < 1 || cz < 1 || cx >= map.grid - 1 || cz >= map.grid - 1 { continue }
            if map.pillarMask[cx + cz * map.grid] != 0 { continue }
            let px = map.cellWorldX(cx) + (scheduleRng.nextUnit() - 0.5) * 2
            let pz = map.cellWorldZ(cz) + (scheduleRng.nextUnit() - 0.5) * 2
            if !map.lineOfSightClear(ax: playerX, az: playerZ, bx: px, bz: pz) { continue }

            x = px
            z = pz
            // Snapped, not eased: a visible spin as it turns to face you would
            // give away that it just arrived.
            yaw = atan2(-(playerX - px), -(playerZ - pz))
            state = .seen
            sightingTimer = 7 + scheduleRng.nextUnit() * 4
            gaze = 0
            fleeTime = 0
            unobservedTime = 0
            events.append(.sighting)
            return
        }
    }

    private mutating func stepSeen(dt: Double, playerX: Double, playerZ: Double,
                                   forwardX: Double, forwardZ: Double,
                                   events: inout [Event]) {
        let dx = playerX - x, dz = playerZ - z
        let dist = max(0.001, (dx * dx + dz * dz).squareRoot())
        let observed = isLookedAt(dx: dx, dz: dz, dist: dist,
                                  forwardX: forwardX, forwardZ: forwardZ,
                                  playerX: playerX, playerZ: playerZ)
        isObserved = observed
        sightingTimer -= dt

        // Fleeing overrides everything: once it breaks it is only running.
        if fleeTime > 0 {
            fleeTime -= dt
            x += fleeDX * EntityPresence.fleeSpeed * dt
            z += fleeDZ * EntityPresence.fleeSpeed * dt
            yaw = atan2(-fleeDX * 10, -fleeDZ * 10)
            if fleeTime <= 0 { despawn(events: &events, event: .sightingEnded) }
            return
        }

        // It closes on you — but only when unobserved, unless it is one of the
        // ones that does not care.
        if (!observed || definition.creepObserved) && dist > definition.minDist + 0.4 {
            let speed = definition.creep * difficulty.creep
            x += dx / dist * speed * dt
            z += dz / dist * speed * dt
        }
        yaw = atan2(-dx, -dz)

        if observed {
            gaze += dt
            if definition.fleeOnGaze && gaze > EntityPresence.fleeGaze {
                breakAndRun(dx: dx, dz: dz, dist: dist, events: &events)
                return
            }
            if definition.gazeVanish && gaze > EntityPresence.vanishGaze {
                despawn(events: &events, event: .vanished)
                return
            }
            unobservedTime = 0
        } else {
            gaze = max(0, gaze - dt * EntityPresence.gazeDecay)
            unobservedTime += dt
            tryReposition(dx: dx, dz: dz, dist: dist,
                          playerX: playerX, playerZ: playerZ, events: &events)
        }

        // Note this tests `dist` as measured *before* this step's creep, which
        // is what the web build does. It costs at most one frame of approach.
        if dist < definition.minDist || sightingTimer <= 0 {
            despawn(events: &events, event: .sightingEnded)
        }
    }

    /// Directly away from the player, then rotated 0.9–1.6 radians to one side
    /// so it disappears around something instead of backing down the corridor
    /// you are already looking along.
    private mutating func breakAndRun(dx: Double, dz: Double, dist: Double,
                                      events: inout [Event]) {
        let bx = -dx / dist, bz = -dz / dist
        let side: Double = reactRng.nextUnit() < 0.5 ? 1 : -1
        let angle = side * (0.9 + reactRng.nextUnit() * 0.7)
        let ca = cos(angle), sa = sin(angle)
        fleeDX = bx * ca - bz * sa
        fleeDZ = bx * sa + bz * ca
        fleeTime = EntityPresence.fleeTime
        events.append(.fled)
    }

    /// The stalker move: look away for long enough and it takes a bite out of
    /// the distance — but only into a cell you cannot see, so you never catch
    /// it moving, you only notice it is closer.
    private mutating func tryReposition(dx: Double, dz: Double, dist: Double,
                                        playerX: Double, playerZ: Double,
                                        events: inout [Event]) {
        guard unobservedTime > EntityPresence.repositionAfter,
              dist > EntityPresence.repositionMinDistance,
              reactRng.nextUnit() < EntityPresence.repositionChance else { return }
        unobservedTime = 0
        let nx = x + dx * EntityPresence.repositionFraction
        let nz = z + dz * EntityPresence.repositionFraction
        let cx = map.worldToCellX(nx), cz = map.worldToCellZ(nz)
        guard cx > 0, cz > 0, cx < map.grid - 1, cz < map.grid - 1,
              map.pillarMask[cx + cz * map.grid] == 0,
              !map.lineOfSightClear(ax: playerX, az: playerZ, bx: nx, bz: nz) else { return }
        x = nx
        z = nz
        events.append(.repositioned)
    }

    private func isLookedAt(dx: Double, dz: Double, dist: Double,
                            forwardX: Double, forwardZ: Double,
                            playerX: Double, playerZ: Double) -> Bool {
        let lookDot = forwardX * (dx / dist) + forwardZ * (dz / dist)
        guard lookDot > EntityPresence.gazeCos, dist < EntityPresence.gazeRange else { return false }
        return map.lineOfSightClear(ax: playerX, az: playerZ, bx: x, bz: z)
    }

    // MARK: - Hunt

    private mutating func startHunt(playerX: Double, playerZ: Double, events: inout [Event]) {
        // Reset the schedule first: the web build does this before the spawn
        // search can bail, so a floor with nowhere to spawn does not retry
        // every frame forever.
        nextHunt = (30 + scheduleRng.nextUnit() * 30) * difficulty.hunt
        telegraphed = false

        let field = map.distanceField(fromX: map.worldToCellX(playerX),
                                      z: map.worldToCellZ(playerZ))
        var candidates: [(Int, Int)] = []
        for cz in 1..<(map.grid - 1) {
            for cx in 1..<(map.grid - 1) {
                let d = field[cx + cz * map.grid]
                if d >= 4 && d <= 7 && map.pillarMask[cx + cz * map.grid] == 0 {
                    candidates.append((cx, cz))
                }
            }
        }
        guard !candidates.isEmpty else { return }
        let pick = candidates[scheduleRng.nextInt(candidates.count)]
        x = map.cellWorldX(pick.0)
        z = map.cellWorldZ(pick.1)
        yaw = atan2(-(playerX - x), -(playerZ - z))
        var chase = EntityHunt(def: definition, map: map, cellX: pick.0, cellZ: pick.1,
                               difficultyHuntTime: difficulty.huntTime,
                               rngSeed: huntSeed, facing: yaw)
        chase.difficultySpeed = difficulty.speed
        hunt = chase
        state = .hunt
        sightingTimer = 0
        gaze = 0
        fleeTime = 0
        events.append(.huntBegan)
    }

    private mutating func stepHunt(dt: Double, playerX: Double, playerZ: Double,
                                   tapesFound: Int, attackReady: Bool,
                                   events: inout [Event]) {
        guard var chase = hunt else {
            state = .idle
            return
        }
        let alive = chase.step(dt: dt, playerX: playerX, playerZ: playerZ,
                               tapesFound: tapesFound, attackReady: attackReady)
        x = chase.x
        z = chase.z
        yaw = chase.yaw
        if chase.reachedAttack { events.append(.attack) }
        // A hunt is never "unobserved" in the sighting sense — it is looking
        // right at you regardless.
        isObserved = true
        if alive {
            hunt = chase
        } else {
            hunt = nil
            despawn(events: &events, event: .huntEnded)
        }
    }

    /// Back to idle. Note this does not touch `nextHunt`: it was already set
    /// when the hunt started, so surviving one does not buy you a fresh count.
    private mutating func despawn(events: inout [Event], event: Event) {
        state = .idle
        hunt = nil
        telegraphed = false
        gaze = 0
        fleeTime = 0
        sightingTimer = 0
        isObserved = false
        unobservedTime = 0
        events.append(event)
    }

    // MARK: - Scheduling hooks

    /// Pull the next hunt in — used when the player does something loud, like
    /// taking a tape.
    public mutating func scheduleHunt(within seconds: Double) {
        nextHunt = min(nextHunt, seconds)
    }

    /// Push it out instead. Used when the game has just disoriented the player
    /// on purpose, so the scare lands as a scare and not an ambush they had no
    /// way to read. Clears the telegraph so the cue fires again on the new time.
    public mutating func delayHunt(to seconds: Double) {
        nextHunt = max(nextHunt, seconds)
        telegraphed = false
    }
}
