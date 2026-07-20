import XCTest
@testable import BackroomsCore

/// Movement fixtures are 480-frame traces produced by the web build's REAL
/// `updatePlayer`, driven by a stored input plan, with colliders overwritten
/// to the wall+pillar set the Swift port also uses. The Swift `PlayerSim`
/// replays the same plan; positions/velocities/stamina must track the trace.
///
/// Tolerance, not hashing: movement uses sin/cos/exp/sqrt whose last bit can
/// differ between JS and Swift libms. A tolerance of 1e-6 m over the whole
/// trace is orders of magnitude tighter than any real bug (which diverges by
/// centimetres to metres) yet immune to libm ULP noise.
final class PlayerSimTests: XCTestCase {

    struct MoveFixture: Decodable {
        let level: Int
        let dt: Double
        let plan: [Step]
        let trace: [Frame]
        struct Step: Decodable { let mx: Double; let mz: Double; let run: Bool; let yaw: Double }
        struct Frame: Decodable {
            let x: Double; let z: Double; let vx: Double; let vz: Double
            let stamina: Double; let groundY: Double
        }
    }

    struct GeoColliders: Decodable { let colliders: [String: [[Double]]] }

    private func load<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func colliders(forLevel level: Int) throws -> [Int: [LevelGeometry.ColliderRect]] {
        let geo = try load("geometry\(level)", GeoColliders.self)
        var out: [Int: [LevelGeometry.ColliderRect]] = [:]
        for (key, rects) in geo.colliders {
            out[Int(key)!] = rects.map { LevelGeometry.ColliderRect(x0: $0[0], z0: $0[1], x1: $0[2], z1: $0[3]) }
        }
        return out
    }

    func testMovementTracksTheWebBuild() throws {
        let tol = 1e-6
        for level in 0..<4 {
            let fix = try load("movement\(level)", MoveFixture.self)
            let map = GameMap.generate(spec: LevelSpec.standardLevels[level], levelIndex: level)
            var sim = PlayerSim(map: map, colliders: try colliders(forLevel: level))

            var maxErr = 0.0
            for (i, step) in fix.plan.enumerated() {
                sim.step(dt: fix.dt, input: PlayerSim.Input(
                    moveX: step.mx, moveZ: step.mz, run: step.run, yaw: step.yaw))
                let f = fix.trace[i]
                maxErr = max(maxErr, abs(sim.x - f.x), abs(sim.z - f.z))
                maxErr = max(maxErr, abs(sim.vx - f.vx), abs(sim.vz - f.vz))
                maxErr = max(maxErr, abs(sim.stamina - f.stamina), abs(sim.groundY - f.groundY))
            }
            XCTAssertLessThan(maxErr, tol,
                "level \(level): trace drift \(maxErr) exceeds \(tol)")
        }
    }

    func testPlayerStartsAtSpawnEyeHeight() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[0], levelIndex: 0)
        let sim = PlayerSim(map: map, colliders: [:])
        XCTAssertEqual(sim.x, map.cellWorldX(map.spawnX))
        XCTAssertEqual(sim.z, map.cellWorldZ(map.spawnZ))
        XCTAssertEqual(sim.stamina, 100)
    }
}
