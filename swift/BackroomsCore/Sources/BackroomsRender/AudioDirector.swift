#if canImport(Metal)
import Foundation
import BackroomsCore

/// Turns game state into sound: footfall cadence, the exit's sonar, the hunt
/// drone and its occlusion, breathing, heartbeat.
///
/// Split out from `GameSession` because it is pure scheduling with no simulation
/// in it — it reads state and emits voices, which makes it testable by counting
/// what it emitted rather than by listening.
public struct AudioDirector {

    /// Metres of travel per footfall, walking. Sprinting shortens the stride.
    public static let strideLength = 2.1
    public static let sprintStrideLength = 1.55
    /// The exit pip's interval, near and far.
    public static let beepIntervalNear = 0.25
    public static let beepIntervalFar = 1.6

    /// Distance at which the hunt drone is at full level.
    public static let droneFullDistance = 8.0
    public static let droneSilentDistance = 34.0

    /// What the director decided this frame. The host plays these and applies
    /// the levels; returning them instead of playing them is what lets a test
    /// assert the schedule.
    public struct Output {
        public var voices: [Voice] = []
        public var waterLevel: Float = 0
        public var breathLevel: Float = 0
        public var droneLevel: Float = 0
        public var dronePan: Float = 0
        public var muffleCutoff: Double = 19_000
    }

    private var strideAccumulator = 0.0
    private var beepTimer = 0.0
    private var heartTimer = 0.0
    private var seed: UInt32 = 4_001
    /// Latched so a transition only fires its sound once.
    private var lastPhase: GameSession.Phase = .playing
    private var lastTapesTotal = 0
    private var lastHealth = 100.0
    private var lastDoorOpening = false

    public init() {}

    private mutating func nextSeed() -> UInt32 {
        seed = seed &+ 2_654_435_761
        return seed
    }

    public mutating func update(session: GameSession, deltaTime: Double,
                                distanceMoved: Double) -> Output {
        var out = Output()
        let theme = session.map.spec.theme

        // --- footfall, driven by distance not time, so it tracks actual speed
        let stride = session.player.moveAmount > 3.6
            ? AudioDirector.sprintStrideLength : AudioDirector.strideLength
        if session.phase == .playing, distanceMoved > 0 {
            strideAccumulator += distanceMoved
            if strideAccumulator >= stride {
                strideAccumulator -= stride
                let running = session.player.moveAmount > 3.6
                // The Poolrooms are ankle-deep in places; the floor decides
                // whether a step is a footfall or a splash.
                if theme == .pool && session.player.groundY < 0.25 {
                    out.voices += SoundBank.splash(running: running, seed: nextSeed())
                } else {
                    out.voices.append(SoundBank.footstep(running: running, seed: nextSeed()))
                }
            }
        }

        // --- the exit's sonar pip, faster as you close
        if session.phase == .playing, let exit = session.exit, exit.revealed {
            let dx = exit.x - session.player.x, dz = exit.z - session.player.z
            let d = (dx * dx + dz * dz).squareRoot()
            beepTimer -= deltaTime
            if beepTimer <= 0 {
                beepTimer = min(AudioDirector.beepIntervalFar,
                                AudioDirector.beepIntervalNear + d * 0.04)
                let gain = Float(max(0.04, min(0.5, 6 / max(1, d))))
                out.voices.append(SoundBank.beep(gain: gain,
                                                 pan: AudioDirector.pan(toX: exit.x, z: exit.z,
                                                                        session: session)))
            }
        }

        // --- the hunt drone: level and pan from the hunter, cutoff from cover
        if let hunter = session.hunter, let d = session.hunterDistance {
            let t = (AudioDirector.droneSilentDistance - d)
                  / (AudioDirector.droneSilentDistance - AudioDirector.droneFullDistance)
            out.droneLevel = Float(max(0, min(1, t))) * 0.5
            out.dronePan = AudioDirector.pan(toX: hunter.x, z: hunter.z, session: session)
            // Behind a wall it is muffled, not merely quieter — that difference
            // is what tells you whether it has line of sight on you.
            let clear = session.map.lineOfSightClear(ax: session.player.x, az: session.player.z,
                                                     bx: hunter.x, bz: hunter.z)
            out.muffleCutoff = clear ? 19_000 : 900

            // Heartbeat, quickening with proximity.
            let interval = max(0.34, 0.95 - (1 - min(1, d / 26)) * 0.5)
            heartTimer -= deltaTime
            if heartTimer <= 0 {
                heartTimer = interval
                out.voices.append(SoundBank.thump(amplitude: Float(0.10 + 0.16 * (1 - min(1, d / 26)))))
            }
        } else {
            heartTimer = 0
        }

        // --- what the entity did this frame
        //
        // Driven by events rather than by watching state flip, because most of
        // these have no state to watch: a reposition leaves the entity in the
        // same phase it was already in, and a sighting that ends by vanishing
        // is indistinguishable afterwards from one that simply timed out. The
        // difference is exactly what the player is supposed to hear.
        for event in session.entityEvents {
            switch event {
            case .telegraph:
                // ~1.4s of warning before it drops in. The growl is the only
                // thing standing between a hunt and an ambush.
                out.voices += SoundBank.growl(seed: nextSeed())
            case .huntBegan:
                switch theme {
                case .warehouse: out.voices.append(SoundBank.houndYelp(seed: nextSeed()))
                case .pipes:     out.voices += SoundBank.crawlerClicks(seed: nextSeed())
                default:         out.voices += SoundBank.growl(seed: nextSeed())
                }
            case .sighting:
                out.voices.append(SoundBank.sightingSting(seed: nextSeed()))
            case .fled:
                out.voices.append(SoundBank.houndYelp(seed: nextSeed()))
                out.voices.append(SoundBank.staticBurst(duration: 0.18, gain: 0.14,
                                                        seed: nextSeed()))
            case .vanished:
                // The tape reacts to what it cannot record.
                out.voices.append(SoundBank.staticBurst(duration: 0.42, gain: 0.22,
                                                        seed: nextSeed()))
            case .repositioned:
                // Quiet. You are meant to half-notice it, not be told.
                out.voices.append(SoundBank.staticBurst(duration: 0.14, gain: 0.10,
                                                        seed: nextSeed()))
            case .sightingEnded, .huntEnded, .attack:
                break
            }
        }

        // --- beds
        out.waterLevel = theme == .pool ? 0.05 : 0
        // Breathing rises as stamina gives out, which is the only cue that you
        // are about to lose your sprint.
        out.breathLevel = Float(max(0, (30 - session.player.stamina) / 30)) * 0.05
        // While it is standing there watching, the room breathes wrong — a bed
        // rather than a one-shot, so it is recomputed every frame and floors
        // whatever stamina was already asking for.
        if session.presence.state == .seen {
            out.breathLevel = max(out.breathLevel, 0.035)
        }

        // --- one-shots on state changes
        if session.tapesTotal > lastTapesTotal {
            out.voices.append(SoundBank.click(seed: nextSeed()))
            out.voices.append(SoundBank.staticBurst(duration: 0.20, gain: 0.10, seed: nextSeed()))
        }
        lastTapesTotal = session.tapesTotal

        if let exit = session.exit, exit.opening, !lastDoorOpening {
            out.voices += SoundBank.creak(seed: nextSeed())
        }
        lastDoorOpening = session.exit?.opening ?? false

        if session.health < lastHealth - 0.5 {
            out.voices += SoundBank.hurt(seed: nextSeed())
        }
        lastHealth = session.health

        if session.phase != lastPhase {
            switch session.phase {
            case .dead:
                out.voices += SoundBank.deathScream(seed: nextSeed())
                out.voices.append(SoundBank.powerDown())
            case .awaitingDescent:
                out.voices.append(SoundBank.whoosh(seed: nextSeed()))
            case .escaped:
                out.voices.append(SoundBank.whoosh(seed: nextSeed()))
            default:
                break
            }
            lastPhase = session.phase
        }
        if session.phase == .dead || session.phase == .escaped {
            out.droneLevel = 0
            out.breathLevel = 0
        }
        return out
    }

    /// Equal-power pan for a world position, relative to where the player is
    /// facing. Matches the web build's `panTo`.
    static func pan(toX x: Double, z: Double, session: GameSession) -> Float {
        let dx = x - session.player.x, dz = z - session.player.z
        let relative = atan2(dx, dz) - (session.player.yaw + .pi)
        return Float(max(-1, min(1, -sin(relative))))
    }
}
#endif
