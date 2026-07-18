/// The map-generation parameters of the four shipping floors, transcribed
/// from `LEVELS` in `web/index.html`. Only fields consumed by `MapGenerator`
/// live here; rendering/audio theming stays with the render layer.
public struct LevelSpec: Sendable {
    public let name: String
    public let grid: Int          // square cell count per side
    public let cellSize: Double   // metres per cell (`cs`)
    public let wallP: Double      // random wall probability
    public let doorP: Double      // chance a wall becomes a doorway
    public let zones: Int         // carved open-zone count
    public let zoneMin: Int
    public let zoneMax: Int
    public let pillarP: Double    // pillar chance inside zones
    public let fixEvery: Int      // ceiling-fixture lattice spacing
    public let fixP: Double       // fixture presence chance
    public let brokenP: Double    // dead fixture chance
    public let flickP: Double     // flickering fixture chance

    public init(name: String, grid: Int, cellSize: Double, wallP: Double,
                doorP: Double, zones: Int, zoneMin: Int, zoneMax: Int,
                pillarP: Double, fixEvery: Int, fixP: Double,
                brokenP: Double, flickP: Double) {
        self.name = name
        self.grid = grid
        self.cellSize = cellSize
        self.wallP = wallP
        self.doorP = doorP
        self.zones = zones
        self.zoneMin = zoneMin
        self.zoneMax = zoneMax
        self.pillarP = pillarP
        self.fixEvery = fixEvery
        self.fixP = fixP
        self.brokenP = brokenP
        self.flickP = flickP
    }

    /// `SEED` from the web build — the date on the camcorder OSD.
    public static let baseSeed: UInt32 = 19_960_923

    /// Per-level seed, matching `mulberry32(SEED + i*7919)`.
    public static func seed(forLevel index: Int) -> UInt32 {
        baseSeed &+ UInt32(index) &* 7919
    }

    public static let standardLevels: [LevelSpec] = [
        LevelSpec(name: "LEVEL 0", grid: 44, cellSize: 6, wallP: 0.46, doorP: 0.26,
                  zones: 9, zoneMin: 4, zoneMax: 9, pillarP: 0.85,
                  fixEvery: 2, fixP: 0.92, brokenP: 0.07, flickP: 0.20),
        LevelSpec(name: "LEVEL 1", grid: 40, cellSize: 8, wallP: 0.30, doorP: 0.22,
                  zones: 12, zoneMin: 5, zoneMax: 10, pillarP: 0.65,
                  fixEvery: 3, fixP: 0.80, brokenP: 0.16, flickP: 0.30),
        LevelSpec(name: "LEVEL 2", grid: 40, cellSize: 5, wallP: 0.62, doorP: 0.30,
                  zones: 3, zoneMin: 3, zoneMax: 5, pillarP: 0,
                  fixEvery: 2, fixP: 0.60, brokenP: 0.18, flickP: 0.35),
        LevelSpec(name: "LEVEL 37", grid: 38, cellSize: 7, wallP: 0.30, doorP: 0.30,
                  zones: 10, zoneMin: 4, zoneMax: 9, pillarP: 0,
                  fixEvery: 2, fixP: 0.85, brokenP: 0.05, flickP: 0.10)
    ]
}
