import XCTest
@testable import BackroomsCore

/// Entity fixtures are 300-frame hunt-chase traces from the web build's REAL
/// `updateEntity` hunt branch: the entity chases a scripted player along a
/// maze route, with `Math.random` seeded so the crawler's burst is
/// deterministic. The Swift `EntityHunt` (fed the same seed and player path)
/// must reproduce position, facing, speed, timer and attack events.
///
/// Tolerance, not hash: hunt movement uses hypot/atan2/division, whose last
/// bit differs between the JS and Swift libms. 1e-6 is far tighter than any
/// real bug yet immune to that noise.
final class EntityHuntTests: XCTestCase {

    struct EntFixture: Decodable {
        let level: Int
        let dt: Double
        let tapesFound: Int
        let rngSeed: UInt32
        let entityCellX: Int
        let entityCellZ: Int
        let ppath: [P]
        let trace: [Frame]
        struct P: Decodable { let x: Double; let z: Double }
        struct Frame: Decodable {
            let x: Double; let z: Double; let yaw: Double
            let speedNow: Double; let timer: Double; let attacked: Bool
        }
    }

    private func load(_ level: Int) throws -> EntFixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/entity\(level)", withExtension: "json"))
        return try JSONDecoder().decode(EntFixture.self, from: Data(contentsOf: url))
    }

    func testHuntChaseTracksTheWebBuild() throws {
        let tol = 1e-6
        for level in 0..<4 {
            let fix = try load(level)
            let map = GameMap.generate(spec: LevelSpec.standardLevels[level], levelIndex: level)
            var hunt = EntityHunt(def: EntityDef.byLevel[level], map: map,
                                  cellX: fix.entityCellX, cellZ: fix.entityCellZ,
                                  rngSeed: fix.rngSeed)

            // Isolated-scenario attack cooldown: set on an attack, never
            // decremented (the player update loop isn't running here).
            var attackCD = 0.0
            var maxErr = 0.0, attackMismatch = 0
            for (i, p) in fix.ppath.enumerated() {
                let attackReady = attackCD <= 0
                _ = hunt.step(dt: fix.dt, playerX: p.x, playerZ: p.z,
                              tapesFound: fix.tapesFound, attackReady: attackReady)
                if hunt.reachedAttack { attackCD = 0.6 }
                let f = fix.trace[i]
                maxErr = max(maxErr, abs(hunt.x - f.x), abs(hunt.z - f.z), abs(hunt.yaw - f.yaw))
                maxErr = max(maxErr, abs(hunt.speedNow - f.speedNow), abs(hunt.timer - f.timer))
                if hunt.reachedAttack != f.attacked { attackMismatch += 1 }
            }
            XCTAssertEqual(attackMismatch, 0, "level \(level): \(attackMismatch) attack-event mismatches")
            XCTAssertLessThan(maxErr, tol, "level \(level): hunt drift \(maxErr) exceeds \(tol)")
        }
    }

    func testEntityDefsMatchTheWebBuild() {
        XCTAssertEqual(EntityDef.byLevel.count, 4)
        XCTAssertEqual(EntityDef.smiler.speed, 3.3)
        XCTAssertEqual(EntityDef.hound.speed, 4.4)
        XCTAssertNotNil(EntityDef.crawler.burst)
        XCTAssertEqual(EntityDef.crawler.burst?.mult, 3.3)
        XCTAssertEqual(EntityDef.drowned.waterSpeed, 4.8)
    }
}
