#if canImport(Metal)
import Foundation
import simd
import Metal
import BackroomsCore

/// Ties the deterministic core to the renderer: owns the level, the player,
/// the hunter and the camera, steps them on a fixed timestep, and keeps the
/// GPU uniforms in sync. A view layer only has to feed it input and hand it a
/// render pass.
public final class GameSession {

    /// Per-floor look, approximating the web build's `LEVELS` environment
    /// entries. Presentation only — nothing here affects simulation.
    public struct Environment {
        public var fog: SIMD3<Float>
        public var fogDensity: Float
        public var ambient: SIMD3<Float>
        public var ambientIntensity: Float
        public var hemiSky: SIMD3<Float>
        public var hemiGround: SIMD3<Float>
        public var hemiIntensity: Float
        public var lightColor: SIMD3<Float>
        public var lightIntensity: Float
        public var lightRange: Float
        public var lightDrop: Float      // fixture offset below the ceiling
        public var exposure: Float

        static func forTheme(_ theme: LevelSpec.Theme) -> Environment {
            switch theme {
            case .lobby:
                return Environment(fog: SIMD3(0.078, 0.063, 0.039), fogDensity: 0.052,
                                   ambient: SIMD3(0.357, 0.329, 0.251), ambientIntensity: 0.50,
                                   hemiSky: SIMD3(0.451, 0.408, 0.298), hemiGround: SIMD3(0.090, 0.071, 0.035),
                                   hemiIntensity: 0.45, lightColor: SIMD3(1.0, 0.914, 0.706),
                                   lightIntensity: 1.15, lightRange: 13.5, lightDrop: 0.25, exposure: 1.05)
            case .warehouse:
                return Environment(fog: SIMD3(0.043, 0.055, 0.063), fogDensity: 0.040,
                                   ambient: SIMD3(0.235, 0.259, 0.282), ambientIntensity: 0.50,
                                   hemiSky: SIMD3(0.298, 0.337, 0.369), hemiGround: SIMD3(0.039, 0.047, 0.055),
                                   hemiIntensity: 0.40, lightColor: SIMD3(0.812, 0.886, 0.933),
                                   lightIntensity: 1.30, lightRange: 17, lightDrop: 1.40, exposure: 1.00)
            case .pipes:
                return Environment(fog: SIMD3(0.098, 0.047, 0.020), fogDensity: 0.085,
                                   ambient: SIMD3(0.290, 0.173, 0.102), ambientIntensity: 0.42,
                                   hemiSky: SIMD3(0.341, 0.196, 0.110), hemiGround: SIMD3(0.071, 0.031, 0.016),
                                   hemiIntensity: 0.35, lightColor: SIMD3(1.0, 0.533, 0.251),
                                   lightIntensity: 1.10, lightRange: 10, lightDrop: 0.22, exposure: 0.98)
            case .pool:
                return Environment(fog: SIMD3(0.682, 0.749, 0.776), fogDensity: 0.030,
                                   ambient: SIMD3(0.561, 0.627, 0.659), ambientIntensity: 0.55,
                                   hemiSky: SIMD3(0.812, 0.878, 0.910), hemiGround: SIMD3(0.298, 0.345, 0.369),
                                   hemiIntensity: 0.55, lightColor: SIMD3(0.918, 0.965, 1.0),
                                   lightIntensity: 1.50, lightRange: 16, lightDrop: 0.30, exposure: 1.12)
            }
        }
    }

    /// What the view layer feeds in each frame.
    public struct Input {
        public var moveX: Double = 0        // −1 left … +1 right
        public var moveZ: Double = 0        // −1 forward … +1 back
        public var run = false
        public var lookDeltaX: Double = 0   // radians accumulated this frame
        public var lookDeltaY: Double = 0
        public var lampOn = true
        public init() {}
    }

    public private(set) var levelIndex: Int
    /// Chosen once at the start of a run and carried down every floor, so the
    /// rules cannot change under you between levels.
    public private(set) var difficulty: Difficulty
    public private(set) var map: GameMap
    public private(set) var geometry: LevelGeometry
    /// Per-theme set dressing — crates, pipework, troffers, pool furniture.
    /// Built once with the floor and reused: it is seeded off the map, so it
    /// does not change when a tape is taken, and regenerating it on every
    /// pickup would rebuild ~20k triangles for nothing.
    private var dressing: PropMesh.Dressing?
    public private(set) var player: PlayerSim
    public private(set) var camera = Camera()
    /// The entity's whole state machine — idle, watching you, or hunting.
    public private(set) var presence: EntityPresence
    /// The chase specifically, non-nil only while it is actually hunting.
    /// Threat cues key off this rather than `presence` so a sighting standing
    /// silently at the end of a corridor does not set off the drone.
    public var hunter: EntityHunt? { presence.hunt }
    /// What the entity did this frame, for audio and HUD. Accumulated across
    /// the frame's fixed steps and cleared at the top of the next `update`.
    public private(set) var entityEvents: [EntityPresence.Event] = []
    public private(set) var uniforms = SceneUniforms()
    /// The tape's condition this frame. Driven from game state in `update`.
    public var tape = VHSUniforms()
    /// What the audio director decided this frame — voices to play and bed
    /// levels to apply. The view layer forwards it to an `AudioHost`; nothing
    /// here touches AVFoundation, so the session still runs headless.
    public private(set) var audio = AudioDirector.Output()
    public private(set) var scene: MetalRenderer.LevelScene?

    /// Seconds until the next hunt begins. Only counts down while the entity is
    /// idle — a hunt does not schedule over itself.
    public var nextHunt: Double { presence.nextHunt }
    public private(set) var pitch: Double = 0
    public private(set) var health: Double = 100
    /// Derived from `phase` rather than stored, so the two cannot drift apart.
    public var isDead: Bool { phase == .dead }
    /// Wall-clock seconds survived on this floor.
    public private(set) var elapsed: Double = 0

    /// Where the run is.
    ///
    /// `awaitingDescent` and `transitioning` are deliberately separate: the
    /// first means "you went through the door, the next floor does not exist
    /// yet", and carries no timer, so the view layer can take as long as it
    /// needs to build it. Only once the floor is ready does the timed cut
    /// start. Collapsing them into one phase lets the timer expire mid-build
    /// and descend you twice.
    public enum Phase: Equatable {
        case playing, awaitingDescent, transitioning, escaped, dead
    }
    public private(set) var phase: Phase = .playing

    public private(set) var tapes: [Objectives.Tape] = []
    public private(set) var exit: Objectives.Exit?
    /// Tapes recovered across the whole run, and on this floor alone.
    public private(set) var tapesTotal = 0
    public private(set) var tapesThisFloor = 0
    /// Seconds left on the between-floors cut.
    public private(set) var transitionTime = 0.0
    /// Set for a few seconds after something worth reading happens.
    public private(set) var message: String?
    private var messageTime = 0.0

    /// Tapes per floor, matching `LEVELS[i].tapes` in the web build.
    public static let tapesPerFloor = 2
    /// Length of the cut between floors.
    public static let transitionLength = 2.6
    /// Stamina a recovered tape gives back — the web build restores battery
    /// and nerve here; stamina is the resource the native build actually has.
    private static let tapeStamina = 22.0
    /// Stamina a starting hunt guarantees you — `max(stamina, 70)` in the web
    /// build. It is not a reward, it is the difference between a chase and an
    /// execution.
    private static let huntStamina = 70.0

    public var tapeGoal: Int { GameSession.tapesPerFloor }
    public var isFinalFloor: Bool { levelIndex == LevelSpec.standardLevels.count - 1 }

    /// Damage per connected swipe, and the seconds between swipes — the web
    /// build's `ATK_CD` and the simple-difficulty `dmg`.
    private static let attackDamage = 10.0
    private static let attackCooldown = 1.0

    private var environment: Environment
    private var accumulator: Double = 0
    private let fixedStep: Double = 1.0 / 60.0
    private var attackTimer: Double = 0
    /// Distance the hunter has travelled, driving its walk cycle.
    private var hunterStride: Double = 0
    /// Wall clock for the tape pass — never reset, so artifacts do not jump
    /// when a floor reloads.
    private var tapeClock: Double = 0
    private var director = AudioDirector()
    /// Distance walked since the last frame, which is what paces footfall.
    private var lastPlayerX: Double = 0
    private var lastPlayerZ: Double = 0
    /// Hunt scheduling and spawn selection.
    private var rng: Mulberry32
    /// Tape and door placement, on its own stream on purpose: sharing one
    /// meant adding a single draw during placement shifted every hunt spawn
    /// downstream of it, which is exactly the coupling that makes a change in
    /// one system silently move another.
    private var objectiveRng: Mulberry32

    public init(levelIndex: Int = 0, renderer: MetalRenderer? = nil,
                difficulty: Difficulty = .standard) {
        let idx = max(0, min(LevelSpec.standardLevels.count - 1, levelIndex))
        self.levelIndex = idx
        self.difficulty = difficulty
        let spec = LevelSpec.standardLevels[idx]
        self.map = GameMap.generate(spec: spec, levelIndex: idx)
        self.geometry = LevelGeometry.build(map: self.map)
        self.dressing = PropMesh.dressing(map: self.map)
        self.player = PlayerSim(map: self.map, colliders: self.geometry.colliderBuckets)
        self.environment = Environment.forTheme(spec.theme)
        self.rng = Mulberry32(seed: LevelSpec.seed(forLevel: idx) &+ 991)
        self.objectiveRng = Mulberry32(seed: LevelSpec.seed(forLevel: idx) &+ 5387)
        self.presence = EntityPresence(def: EntityDef.byLevel[idx], map: self.map,
                                       seed: LevelSpec.seed(forLevel: idx),
                                       difficulty: difficulty.entity)
        applyEnvironment()
        placeObjectives()
        // Seed the footfall pacer at spawn, or the first frame reads the whole
        // distance from the origin as ground covered.
        self.lastPlayerX = player.x
        self.lastPlayerZ = player.z
        if let renderer {
            scene = renderer.makeScene(map: map, geometry: geometry)
            uploadProps(renderer)
        }
    }

    /// Scatter this floor's tapes and drop the door at the far end.
    private func placeObjectives() {
        tapes = Objectives.placeTapes(map: map, count: GameSession.tapesPerFloor,
                                      rng: &objectiveRng)
        exit = Objectives.placeExitFar(map: map)
        tapesThisFloor = 0
    }

    private func uploadProps(_ renderer: MetalRenderer) {
        guard var scene = self.scene else { return }
        let currentMap = map
        let ground: (Double, Double) -> Double = { x, z in
            currentMap.groundHeight(atX: x, z: z)
        }
        renderer.updateProps(in: &scene,
                             dark: PropMesh.dark(tapes: tapes, exit: exit,
                                                 dressing: dressing, groundY: ground),
                             bright: PropMesh.bright(tapes: tapes, exit: exit,
                                                     dressing: dressing, groundY: ground))
        self.scene = scene
    }

    /// Rebuild for a different floor, reusing the renderer's device.
    public func load(levelIndex idx: Int, renderer: MetalRenderer?) {
        let clamped = max(0, min(LevelSpec.standardLevels.count - 1, idx))
        levelIndex = clamped
        let spec = LevelSpec.standardLevels[clamped]
        map = GameMap.generate(spec: spec, levelIndex: clamped)
        geometry = LevelGeometry.build(map: map)
        dressing = PropMesh.dressing(map: map)
        player = PlayerSim(map: map, colliders: geometry.colliderBuckets)
        environment = Environment.forTheme(spec.theme)
        rng = Mulberry32(seed: LevelSpec.seed(forLevel: clamped) &+ 991)
        objectiveRng = Mulberry32(seed: LevelSpec.seed(forLevel: clamped) &+ 5387)
        presence = EntityPresence(def: EntityDef.byLevel[clamped], map: map,
                                  seed: LevelSpec.seed(forLevel: clamped),
                                  difficulty: difficulty.entity)
        entityEvents = []
        pitch = 0
        health = 100
        phase = .playing
        elapsed = 0
        accumulator = 0
        attackTimer = 0
        hunterStride = 0
        transitionTime = 0
        message = nil
        messageTime = 0
        applyEnvironment()
        placeObjectives()
        lastPlayerX = player.x
        lastPlayerZ = player.z
        if let renderer {
            scene = renderer.makeScene(map: map, geometry: geometry)
            uploadProps(renderer)
        }
    }

    /// Restart the current floor after a death. Same seed, so it is the same
    /// building — you are meant to learn it, not reroll it. Tapes already
    /// banked on deeper floors stay banked; this floor's go back.
    public func restart(renderer: MetalRenderer?) {
        tapesTotal -= tapesThisFloor
        load(levelIndex: levelIndex, renderer: renderer)
    }

    /// Start the run over from the top floor.
    public func restartRun(renderer: MetalRenderer?) {
        tapesTotal = 0
        load(levelIndex: 0, renderer: renderer)
    }

    private func applyEnvironment() {
        let e = environment
        uniforms.ambient = SIMD4(e.ambient.x, e.ambient.y, e.ambient.z, e.ambientIntensity)
        uniforms.hemiSky = SIMD4(e.hemiSky.x, e.hemiSky.y, e.hemiSky.z, e.hemiIntensity)
        uniforms.hemiGround = SIMD4(e.hemiGround.x, e.hemiGround.y, e.hemiGround.z, e.fogDensity)
        uniforms.fogColor = SIMD4(e.fog.x, e.fog.y, e.fog.z, Float(map.spec.wallHeight))
        uniforms.flashParams = SIMD4(0.94, 0.76, 26, e.exposure)
    }

    // MARK: - Update

    /// Advances the game. Real frame time is accumulated and consumed in fixed
    /// steps so physics stays deterministic regardless of display rate.
    public func update(deltaTime: Double, input: Input, aspect: Float) {
        // Look is applied per frame, not per step: it is input, not simulation.
        camera.yaw -= Float(input.lookDeltaX)
        pitch = max(-1.45, min(1.45, pitch - input.lookDeltaY))
        // Events are per-frame, not per-step: the audio director runs once a
        // frame, so anything left over from last frame would fire twice.
        entityEvents.removeAll(keepingCapacity: true)

        if messageTime > 0 {
            messageTime -= deltaTime
            if messageTime <= 0 { message = nil }
        }

        if phase == .transitioning {
            // The floor underneath is already the new one; the player just
            // cannot act until the card clears.
            transitionTime -= deltaTime
            if transitionTime <= 0 { phase = .playing }
        } else if phase == .playing {
            accumulator += min(deltaTime, 0.25)     // never spiral after a stall
            while accumulator >= fixedStep {
                step(fixedStep, input: input)
                accumulator -= fixedStep
            }
            elapsed += deltaTime
        }

        // `follow` also copies the player's yaw back onto the camera. The
        // camera is the authority here — the player derives its heading from it
        // each step — so restore it, or a frame that consumed no fixed step
        // (a 120Hz display, a short frame) would throw that frame's look away.
        let lookYaw = camera.yaw
        camera.follow(player: player, groundY: Float(player.groundY))
        camera.yaw = lookYaw
        camera.pitch = Float(pitch)
        camera.aspect = aspect
        camera.fov = (input.run && player.moveAmount > 3.6) ? Camera.sprintFOV : Camera.baseFOV

        uniforms.apply(camera: camera)
        uniforms.loadNearestLights(
            from: map, playerX: player.x, playerZ: player.z,
            lightY: Float(map.spec.wallHeight) - environment.lightDrop,
            color: environment.lightColor,
            intensity: environment.lightIntensity, range: environment.lightRange)
        let lamp: Float = input.lampOn ? 2.6 : 0
        uniforms.flash = SIMD4(1.0, 0.953, 0.847, lamp)
        // `elapsed` freezes on death and resets per floor, but the tape has
        // been running the whole time — give it its own clock.
        tapeClock += deltaTime
        // Mutated through a local so the inout access to `tape` never overlaps
        // the reads of `self` that `apply` makes.
        var tapeState = tape
        tapeState.apply(session: self, elapsed: tapeClock)
        tape = tapeState

        // Footfall is paced by ground covered, not by time, so it stays in step
        // whether you are walking, sprinting or being slowed by water.
        let moved = ((player.x - lastPlayerX) * (player.x - lastPlayerX)
                     + (player.z - lastPlayerZ) * (player.z - lastPlayerZ)).squareRoot()
        lastPlayerX = player.x
        lastPlayerZ = player.z
        audio = director.update(session: self, deltaTime: deltaTime, distanceMoved: moved)
    }

    private func step(_ dt: Double, input: Input) {
        let pi = PlayerSim.Input(moveX: input.moveX, moveZ: input.moveZ,
                                 run: input.run, yaw: Double(camera.yaw))
        player.step(dt: dt, input: pi)

        attackTimer = max(0, attackTimer - dt)

        // The camera is what decides whether the thing is being looked at, so
        // the sighting phase reads the same forward vector the renderer uses.
        let f = camera.forward
        let events = presence.step(dt: dt, playerX: player.x, playerZ: player.z,
                                   forwardX: Double(f.x), forwardZ: Double(f.z),
                                   tapesFound: tapesThisFloor,
                                   attackReady: attackTimer <= 0)
        for event in events {
            switch event {
            case .attack:
                attackTimer = GameSession.attackCooldown
                health = max(0, health - GameSession.attackDamage)
                if health <= 0 { phase = .dead }
            case .huntBegan:
                // Adrenaline: you always get a chance to run, even if you were
                // already spent when it dropped in.
                if player.stamina < GameSession.huntStamina {
                    player.restoreStamina(GameSession.huntStamina - player.stamina)
                }
                say("—— THE SIGNAL IS SCREAMING. DO NOT STOP MOVING. ——")
            case .vanished:
                say("…IT WAS THERE. YOU LOOKED. IT WASN'T.")
            default:
                break
            }
        }
        entityEvents += events
        hunterStride = presence.stride

        updateExit(dt)
    }

    // MARK: - Objectives

    /// The door announces itself once you are close, and carries you through
    /// once it has finished swinging and you are still standing in it.
    private func updateExit(_ dt: Double) {
        guard var e = exit else { return }
        let dx = e.x - player.x, dz = e.z - player.z
        let d = (dx * dx + dz * dz).squareRoot()

        if !e.revealed && d < Objectives.revealDistance {
            e.revealed = true
            say("YOU FOUND A DOOR. IT HUMS. IT KNOWS WHERE DOWN IS.")
        }
        if e.opening {
            e.openTime += dt
            if e.openTime > Objectives.doorOpenTime * 0.5 && d < Objectives.throughDoorDistance {
                exit = e
                goThroughDoor()
                return
            }
        }
        exit = e
    }

    /// What `[E]` / USE would act on right now, for the view layer's prompt.
    public var availableInteraction: Objectives.Interaction? {
        guard phase == .playing else { return nil }
        let f = camera.forward
        return Objectives.findInteraction(tapes: tapes, exit: exit,
                                          playerX: player.x, playerZ: player.z,
                                          forwardX: Double(f.x), forwardZ: Double(f.z))
    }

    /// Act on it. Returns what was acted on, so the view layer can fire the
    /// matching haptic without re-deriving it.
    @discardableResult
    public func interact(renderer: MetalRenderer?) -> Objectives.Interaction? {
        guard let action = availableInteraction else { return nil }
        switch action {
        case .tape(let index):
            guard let i = tapes.firstIndex(where: { $0.index == index && !$0.found }) else { return nil }
            tapes[i].found = true
            tapesTotal += 1
            tapesThisFloor += 1
            player.restoreStamina(GameSession.tapeStamina)
            // Taking a tape is loud. The web build pulls the next hunt in to
            // 2–5s, so the reward always costs you something.
            presence.scheduleHunt(within: 2 + rng.nextUnit() * 3)

            if tapesThisFloor >= GameSession.tapesPerFloor {
                relocateExit()
            } else {
                say("TAPE RECOVERED — \(tapesThisFloor)/\(GameSession.tapesPerFloor) ON THIS FLOOR")
            }
            if let renderer { uploadProps(renderer) }

        case .door:
            guard var e = exit, !e.opening else { return nil }
            e.opening = true
            e.openTime = 0
            exit = e
        }
        return action
    }

    /// The last tape drags the door to you. It also buys a window to run for
    /// it — without one, the hunt pulled in above lands while you are still
    /// reading the message, which reads as an unavoidable ambush.
    private func relocateExit() {
        guard var e = exit else { return }
        if let spot = Objectives.relocatedExit(map: map, playerX: player.x,
                                               playerZ: player.z, rng: &objectiveRng) {
            e.x = spot.x
            e.z = spot.z
        }
        e.revealed = true
        e.opening = false
        e.openTime = 0
        exit = e
        presence.delayHunt(to: 11)
        say("THE TAPES SANG — A DOOR TORE ITSELF THROUGH A WALL NEARBY.")
    }

    private func goThroughDoor() {
        if isFinalFloor {
            phase = .escaped
            presence.dismiss()
        } else {
            // No timer yet — the next floor has not been built.
            phase = .awaitingDescent
        }
    }

    /// Build the next floor. The view layer calls this during the cut, so the
    /// second or so of texture and geometry work is hidden by the card.
    public func advanceToNextFloor(renderer: MetalRenderer?) {
        guard levelIndex + 1 < LevelSpec.standardLevels.count else { return }
        // `load` resets the floor but never the run total, so tapes banked on
        // the floors above carry down.
        load(levelIndex: levelIndex + 1, renderer: renderer)
        phase = .transitioning
        transitionTime = GameSession.transitionLength
    }

    private func say(_ text: String) {
        message = text
        messageTime = 5.0
    }

    /// See `PlayerSim.teleport` — for tests, not for the game.
    public func debugTeleport(x: Double, z: Double) {
        player.teleport(x: x, z: z)
        // Without this the next frame reads the jump as ground covered and
        // fires a stride's worth of footsteps.
        lastPlayerX = x
        lastPlayerZ = z
    }

    /// Distance to the hunter, for a view layer that wants to show threat.
    /// Nil during a sighting on purpose — the HUD warns you about the chase,
    /// not about the thing quietly watching you.
    public var hunterDistance: Double? {
        guard let h = hunter else { return nil }
        let dx = h.x - player.x, dz = h.z - player.z
        return (dx * dx + dz * dz).squareRoot()
    }

    /// Straight-line distance to the exit, or nil before one is placed.
    public var exitDistance: Double? {
        guard let exit else { return nil }
        let dx = exit.x - player.x, dz = exit.z - player.z
        return (dx * dx + dz * dz).squareRoot()
    }

    /// The closest tape still out there on this floor, with its distance.
    /// Only meaningful under a difficulty that advertises tapes — the caller
    /// decides that, since the nearest tape is also useful to the audio.
    public var nearestUnfoundTape: (tape: Objectives.Tape, distance: Double)? {
        var best: (Objectives.Tape, Double)?
        for t in tapes where !t.found {
            let dx = t.x - player.x, dz = t.z - player.z
            let d = (dx * dx + dz * dz).squareRoot()
            if best == nil || d < best!.1 { best = (t, d) }
        }
        guard let best else { return nil }
        return (tape: best.0, distance: best.1)
    }

    /// Screen-space bearing to a world point, in radians, ready to drop into a
    /// rotation transform: 0 means dead ahead, positive turns clockwise.
    ///
    /// This is the web build's arrow math — `atan2(dx, dz) - (yaw + π)`, negated
    /// — kept in the session so both the compass arrows and anything else that
    /// wants a heading agree by construction.
    public func bearing(toX x: Double, z: Double) -> Double {
        -(atan2(x - player.x, z - player.z) - (player.yaw + Double.pi))
    }

    /// Distance to the entity in whatever state it is in, or nil while idle.
    public var entityDistance: Double? {
        guard presence.isVisible else { return nil }
        let dx = presence.x - player.x, dz = presence.z - player.z
        return (dx * dx + dz * dz).squareRoot()
    }

    /// The entity's silhouette in world space, rebuilt each frame, or nil while
    /// it is off the map. Hand straight to `MetalRenderer.draw(entity:)`.
    public var entityMesh: InterleavedMesh? {
        guard presence.isVisible else { return nil }
        return EntityMesh.stickman(x: Float(presence.x),
                                   groundY: Float(map.groundHeight(atX: presence.x,
                                                                   z: presence.z)),
                                   z: Float(presence.z),
                                   yaw: Float(presence.yaw),
                                   phase: Float(hunterStride))
    }
}
#endif
