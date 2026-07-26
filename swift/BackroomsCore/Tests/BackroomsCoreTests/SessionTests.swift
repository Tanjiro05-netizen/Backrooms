import XCTest
@testable import BackroomsCore
@testable import BackroomsRender

#if canImport(Metal)

/// Covers `GameSession` — the glue that turns the tested-in-isolation core
/// (map, player, hunter) into a playable loop. No GPU is touched: a session
/// built with a nil renderer simulates fully, which is exactly why the
/// simulation was kept out of the renderer in the first place.
///
/// Every test drives the session at a fixed 1/60 so runs are reproducible.
final class SessionTests: XCTestCase {

    private let step = 1.0 / 60.0

    private func advance(_ session: GameSession, seconds: Double,
                         input: GameSession.Input = GameSession.Input()) {
        for _ in 0..<Int(seconds / step) {
            session.update(deltaTime: step, input: input, aspect: 16.0 / 9.0)
        }
    }

    // MARK: - Hunt lifecycle

    func testHunterSpawnsAfterTheTelegraphAndClosesIn() throws {
        let session = GameSession(levelIndex: 0)
        // Level 0's telegraph is huntTime × 0.8 = 20.8s.
        XCTAssertEqual(session.nextHunt, 26 * 0.8, accuracy: 1e-9)
        XCTAssertNil(session.hunter, "nothing should hunt on spawn")

        advance(session, seconds: 15)
        XCTAssertNil(session.hunter, "hunt began early — the telegraph is the whole warning")

        advance(session, seconds: 8)
        XCTAssertNotNil(session.hunter, "hunt never began")

        let first = try XCTUnwrap(session.hunterDistance)
        advance(session, seconds: 3)
        let later = try XCTUnwrap(session.hunterDistance)
        XCTAssertLessThan(later, first, "the hunter must actually close on a stationary player")
    }

    /// It spawns out of sight, not on top of you: the web build picks a cell
    /// 4–7 rooms away by BFS, so on level 0 (6m cells) that is roughly 24–42m.
    func testHunterSpawnsAtAFairDistance() throws {
        for level in 0..<LevelSpec.standardLevels.count {
            let session = GameSession(levelIndex: level)
            advance(session, seconds: EntityDef.byLevel[level].huntTime * 0.8 + 0.5)
            let d = try XCTUnwrap(session.hunterDistance,
                                  "level \(level) never spawned a hunter")
            let cell = LevelSpec.standardLevels[level].cellSize
            XCTAssertGreaterThan(d, cell * 3, "level \(level) spawned the hunter on top of the player")
            XCTAssertLessThan(d, cell * 9, "level \(level) spawned the hunter unreachably far")
        }
    }

    // MARK: - Death and restart

    func testStandingStillGetsYouKilledAndRewindRestores() {
        let session = GameSession(levelIndex: 0)
        XCTAssertEqual(session.health, 100)

        // Long enough for a second hunt if the first times out on a bad path.
        advance(session, seconds: 120)
        XCTAssertTrue(session.isDead, "a stationary player must not survive a full hunt")
        XCTAssertEqual(session.health, 0)

        // Dead sessions freeze: no more simulation until rewound.
        let frozen = session.elapsed
        advance(session, seconds: 5)
        XCTAssertEqual(session.elapsed, frozen, accuracy: 1e-9)

        session.restart(renderer: nil)
        XCTAssertFalse(session.isDead)
        XCTAssertEqual(session.health, 100)
        XCTAssertEqual(session.elapsed, 0)
        XCTAssertNil(session.hunter)
        XCTAssertEqual(session.levelIndex, 0, "rewind stays on the same floor")
    }

    /// Same seed on restart — the building must be the one you just learned.
    func testRestartRegeneratesTheIdenticalFloor() {
        let session = GameSession(levelIndex: 1)
        let before = Fnv64.hash(floats: LevelGeometry.build(map: session.map)
            .wallChunks.compactMap { $0 }.flatMap { $0.positions })
        session.restart(renderer: nil)
        let after = Fnv64.hash(floats: LevelGeometry.build(map: session.map)
            .wallChunks.compactMap { $0 }.flatMap { $0.positions })
        XCTAssertEqual(before, after)
    }

    // MARK: - Movement

    func testHoldingForwardKeepsThePlayerInsideTheLevel() {
        let session = GameSession(levelIndex: 0)
        var input = GameSession.Input()
        input.moveZ = -1          // forward
        input.run = true

        // Sweep the view around so the player is driven at every wall in reach.
        // The bounds are checked every frame, not just at the end: a single
        // tunnelling frame is the bug, and it would be walked back by the next.
        let half = Double(session.map.grid) * session.map.spec.cellSize / 2
        for i in 0..<(60 * 40) {
            input.lookDeltaX = (i % 120 == 0) ? 0.5 : 0
            session.update(deltaTime: step, input: input, aspect: 16.0 / 9.0)
            guard !session.isDead else { break }   // the hunter caught them; nothing left to test
            XCTAssertLessThan(abs(session.player.x), half, "player escaped the level in x at frame \(i)")
            XCTAssertLessThan(abs(session.player.z), half, "player escaped the level in z at frame \(i)")
            XCTAssertGreaterThanOrEqual(session.player.stamina, 0)
            XCTAssertLessThanOrEqual(session.player.stamina, 100)
        }
    }

    // MARK: - Entity geometry

    func testEntityMeshIsAbsentUntilSomethingHunts() {
        let session = GameSession(levelIndex: 0)
        XCTAssertNil(session.entityMesh)
        advance(session, seconds: 21.5)
        XCTAssertNotNil(session.entityMesh, "a hunting entity that draws nothing is invisible")
    }

    func testStickmanIsWellFormedAndStandsWhereTheHunterIs() {
        let mesh = EntityMesh.stickman(x: 12, groundY: 0.5, z: -7, yaw: 0.9, phase: 3.1)
        XCTAssertEqual(mesh.vertexCount, 7 * 36, "seven boxes, six faces, two triangles each")
        XCTAssertEqual(mesh.vertices.count % InterleavedMesh.floatsPerVertex, 0)

        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var maxRadius: Float = 0
        for i in 0..<mesh.vertexCount {
            let b = i * InterleavedMesh.floatsPerVertex
            let px = mesh.vertices[b], py = mesh.vertices[b + 1], pz = mesh.vertices[b + 2]
            minY = min(minY, py); maxY = max(maxY, py)
            maxRadius = max(maxRadius, (pow(px - 12, 2) + pow(pz + 7, 2)).squareRoot())

            let nx = mesh.vertices[b + 3], ny = mesh.vertices[b + 4], nz = mesh.vertices[b + 5]
            XCTAssertEqual((nx * nx + ny * ny + nz * nz).squareRoot(), 1, accuracy: 1e-5,
                           "normal \(i) is not unit length — rotating it went wrong")
            XCTAssertFalse(px.isNaN || py.isNaN || pz.isNaN)
        }
        XCTAssertEqual(minY, 0.5, accuracy: 1e-4, "the stickman must stand on the floor, not in it")
        XCTAssertGreaterThan(maxY, 0.5 + EntityMesh.height * 0.9, "too short to be the silhouette")
        XCTAssertLessThan(maxY, 0.5 + EntityMesh.height * 1.15)
        XCTAssertLessThan(maxRadius, 0.6, "limbs splayed far wider than a body")
    }

    /// The walk cycle has to be driven by the phase, or the entity slides
    /// toward you like furniture.
    func testStickmanLimbsMoveWithPhase() {
        let a = EntityMesh.stickman(x: 0, groundY: 0, z: 0, yaw: 0, phase: 0.0)
        let b = EntityMesh.stickman(x: 0, groundY: 0, z: 0, yaw: 0, phase: 0.6)
        XCTAssertEqual(a.vertices.count, b.vertices.count)
        let moved = zip(a.vertices, b.vertices).contains { abs($0 - $1) > 1e-3 }
        XCTAssertTrue(moved, "the silhouette is identical at two phases — no walk cycle")
    }
}

#endif
