/// Per-entity behaviour parameters, transcribed from `ENTITY_DEFS` in the web
/// build. Only the fields the hunt simulation consumes are modelled here;
/// sighting/flee/gaze behaviour ports with those phases later.
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
    public let minDist: Double
    public let burst: Burst?

    public init(name: String, speed: Double, waterSpeed: Double? = nil,
                huntTime: Double, catchR: Double, minDist: Double, burst: Burst? = nil) {
        self.name = name
        self.speed = speed
        self.waterSpeed = waterSpeed
        self.huntTime = huntTime
        self.catchR = catchR
        self.minDist = minDist
        self.burst = burst
    }

    /// One per floor, matching the web build's `ENTITY_DEFS` order.
    public static let smiler = EntityDef(name: "THE SMILER", speed: 3.3,
        huntTime: 26, catchR: 1.15, minDist: 6.0)
    public static let hound = EntityDef(name: "THE HOUND", speed: 4.4,
        huntTime: 17, catchR: 1.05, minDist: 6.5)
    public static let crawler = EntityDef(name: "THE CRAWLER", speed: 2.3,
        huntTime: 28, catchR: 1.20, minDist: 4.5,
        burst: Burst(period: 2.3, duration: 0.6, mult: 3.3))
    public static let drowned = EntityDef(name: "THE DROWNED", speed: 2.4, waterSpeed: 4.8,
        huntTime: 26, catchR: 1.15, minDist: 5.0)

    /// The entity that hunts each floor, by level index.
    public static let byLevel: [EntityDef] = [smiler, hound, crawler, drowned]
}
