import XCTest
@testable import BackroomsCore

/// Fixtures are dumped from the shipping JS game (see tools/ and the web
/// build): for each floor they capture the full wall/zone/pillar arrays and
/// fixture list. These tests prove the Swift core generates the *identical*
/// world — the foundation contract of the native port.
final class MapGeneratorTests: XCTestCase {

    struct Fixture: Decodable {
        let level: Int
        let grid: Int
        let seed: UInt32
        let spawnX: Int
        let spawnZ: Int
        let vWallA: [UInt8]
        let hWallA: [UInt8]
        let zoneMask: [UInt8]
        let pillarMask: [UInt8]
        let fixtures: [Fix]
        struct Fix: Decodable { let cellX: Int; let cellZ: Int; let flicker: Bool }
    }

    private func loadFixture(_ level: Int) throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/level\(level)", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testAllFourFloorsMatchTheWebBuildExactly() throws {
        for level in 0..<4 {
            let fix = try loadFixture(level)
            let spec = LevelSpec.standardLevels[level]
            XCTAssertEqual(spec.grid, fix.grid, "level \(level) grid")
            XCTAssertEqual(LevelSpec.seed(forLevel: level), fix.seed, "level \(level) seed")

            let map = GameMap.generate(spec: spec, levelIndex: level)
            XCTAssertEqual(map.spawnX, fix.spawnX, "level \(level) spawnX")
            XCTAssertEqual(map.spawnZ, fix.spawnZ, "level \(level) spawnZ")
            XCTAssertEqual(map.vWalls, fix.vWallA, "level \(level) vertical walls")
            XCTAssertEqual(map.hWalls, fix.hWallA, "level \(level) horizontal walls")
            XCTAssertEqual(map.zoneMask, fix.zoneMask, "level \(level) zones")
            XCTAssertEqual(map.pillarMask, fix.pillarMask, "level \(level) pillars")
            XCTAssertEqual(map.fixtures.count, fix.fixtures.count, "level \(level) fixture count")
            for (a, b) in zip(map.fixtures, fix.fixtures) {
                XCTAssertEqual(a.cellX, b.cellX)
                XCTAssertEqual(a.cellZ, b.cellZ)
                XCTAssertEqual(a.flicker, b.flicker)
            }
        }
    }

    func testWorldIsOverwhelminglyReachableFromSpawn() {
        // The web build's connectivity pass punches doorways only in the
        // +x/+z direction, so a handful of pockets can stay sealed (7 cells
        // across all four shipping floors). That is the real game's shape —
        // content placement only ever uses BFS-reachable cells, so sealed
        // pockets are invisible in play. Assert the honest invariant: the
        // world is overwhelmingly connected, and spawn always is.
        for level in 0..<4 {
            let spec = LevelSpec.standardLevels[level]
            let map = GameMap.generate(spec: spec, levelIndex: level)
            let dist = map.distanceField(fromX: map.spawnX, z: map.spawnZ)
            var open = 0, reachable = 0
            for z in 0..<map.grid { for x in 0..<map.grid {
                let i = x + z * map.grid
                if map.pillarMask[i] == 0 {
                    open += 1
                    if dist[i] >= 0 { reachable += 1 }
                }
            } }
            XCTAssertGreaterThanOrEqual(dist[map.spawnX + map.spawnZ * map.grid], 0)
            let fraction = Double(reachable) / Double(open)
            XCTAssertGreaterThanOrEqual(fraction, 0.99,
                "level \(level): only \(reachable)/\(open) cells reachable")
        }
    }

    func testLineOfSightBasics() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[0], levelIndex: 0)
        let sx = map.cellWorldX(map.spawnX), sz = map.cellWorldZ(map.spawnZ)
        // A point is always visible from itself's cell.
        XCTAssertTrue(map.lineOfSightClear(ax: sx, az: sz, bx: sx + 0.5, bz: sz))
        // The spawn pocket is carved open 3x3, so one cell over is visible.
        XCTAssertTrue(map.lineOfSightClear(
            ax: sx, az: sz, bx: map.cellWorldX(map.spawnX + 1), bz: sz))
    }

    func testRngMatchesReferenceStream() {
        // First output of mulberry32(19960923), captured from the JS engine.
        var rng = Mulberry32(seed: 19_960_923)
        XCTAssertEqual(rng.nextUnit(), 0.6350537554826587, accuracy: 0)
        // Determinism: same seed, same stream.
        var a = Mulberry32(seed: 42), b = Mulberry32(seed: 42)
        for _ in 0..<1000 { XCTAssertEqual(a.nextUnit(), b.nextUnit()) }
    }
}
