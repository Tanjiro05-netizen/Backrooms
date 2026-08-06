/// Per-entity behaviour parameters, transcribed from `ENTITY_DEFS` in the web
/// build. Everything the simulation reads is here; the `build`/`animate`
/// function references in the JS table are presentation and live in the
/// renderer's mesh code instead.
public struct EntityDef: Sendable {
    public struct Burst: Sendable {
        public let period: Double   // seconds between bursts (× random 0.7–1.3)
        public let duration: Double // burst length
        public let mult: Double     // speed multiplier during a burst
    }

    public let name: String
    public let speed: Double
    public let waterSpeed: Double?   // faster while inside a pool water zone
    public let huntTime: Double
    public let catchR: Double
    /// Both the closest a sighting will stand and the range at which one
    /// breaks off — get inside it and the thing is gone before you reach it.
    public let minDist: Double
    public let burst: Burst?

    // --- sighting phase

    /// How far ahead of the player a sighting is placed.
    public let sightMin: Double
    public let sightMax: Double
    /// Metres per second it closes while merely watching you.
    public let creep: Double
    /// Whether it keeps creeping while you are looking straight at it. The
    /// smiler and hound freeze under a gaze; the crawler and drowned do not
    /// care, which is what makes them the ones you cannot stare down.
    public let creepObserved: Bool
    /// Hold your gaze long enough and it simply is not there any more.
    public let gazeVanish: Bool
    /// Or it bolts — the hound breaks and runs the moment it is caught.
    public let fleeOnGaze: Bool
    /// Seconds before this floor's first hunt, `baseHuntDelay` in the web build.
    public let baseHuntDelay: Double

    public init(name: String, speed: Double, waterSpeed: Double? = nil,
                huntTime: Double, catchR: Double, minDist: Double, burst: Burst? = nil,
                sightMin: Double, sightMax: Double, creep: Double,
                creepObserved: Bool, gazeVanish: Bool, fleeOnGaze: Bool,
                baseHuntDelay: Double) {
        self.name = name
        self.speed = speed
        self.waterSpeed = waterSpeed
        self.huntTime = huntTime
        self.catchR = catchR
        self.minDist = minDist
        self.burst = burst
        self.sightMin = sightMin
        self.sightMax = sightMax
        self.creep = creep
        self.creepObserved = creepObserved
        self.gazeVanish = gazeVanish
        self.fleeOnGaze = fleeOnGaze
        self.baseHuntDelay = baseHuntDelay
    }

    /// One per floor, matching the web build's `ENTITY_DEFS` order.
    public static let smiler = EntityDef(name: "THE SMILER", speed: 3.3,
        huntTime: 26, catchR: 1.15, minDist: 6.0,
        sightMin: 13, sightMax: 24, creep: 0.55,
        creepObserved: false, gazeVanish: true, fleeOnGaze: false, baseHuntDelay: 45)
    public static let hound = EntityDef(name: "THE HOUND", speed: 4.4,
        huntTime: 17, catchR: 1.05, minDist: 6.5,
        sightMin: 14, sightMax: 26, creep: 0.50,
        creepObserved: false, gazeVanish: false, fleeOnGaze: true, baseHuntDelay: 26)
    public static let crawler = EntityDef(name: "THE CRAWLER", speed: 2.3,
        huntTime: 28, catchR: 1.20, minDist: 4.5,
        burst: Burst(period: 2.3, duration: 0.6, mult: 3.3),
        sightMin: 10, sightMax: 18, creep: 0.70,
        creepObserved: true, gazeVanish: false, fleeOnGaze: false, baseHuntDelay: 18)
    public static let drowned = EntityDef(name: "THE DROWNED", speed: 2.4, waterSpeed: 4.8,
        huntTime: 26, catchR: 1.15, minDist: 5.0,
        sightMin: 12, sightMax: 22, creep: 0.60,
        creepObserved: true, gazeVanish: false, fleeOnGaze: false, baseHuntDelay: 20)

    /// The entity that hunts each floor, by level index.
    public static let byLevel: [EntityDef] = [smiler, hound, crawler, drowned]
}

/// The difficulty multipliers the entity reads, from the web build's `DIFFS`.
/// Only the entity-facing fields are here; player drain and damage live with
/// the player.
public struct EntityDifficulty: Sendable {
    public var hunt: Double        // scales the gap between hunts
    public var sight: Double       // scales the gap between sightings
    public var speed: Double       // chase speed
    public var huntTime: Double    // how long a hunt lasts
    public var creep: Double       // how fast a sighting closes on you

    public init(hunt: Double, sight: Double, speed: Double,
                huntTime: Double, creep: Double) {
        self.hunt = hunt
        self.sight = sight
        self.speed = speed
        self.huntTime = huntTime
        self.creep = creep
    }

    public static let standard = EntityDifficulty(hunt: 1.0, sight: 1.0, speed: 1.0,
                                                  huntTime: 1.0, creep: 1.0)
    public static let simple = EntityDifficulty(hunt: 3.2, sight: 2.2, speed: 0.60,
                                                huntTime: 0.45, creep: 0.4)
}
