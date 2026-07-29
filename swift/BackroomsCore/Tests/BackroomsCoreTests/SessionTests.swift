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

    // MARK: - The run

    /// Teleporting is not something the game does, but a test that had to
    /// physically walk 200m of corridor would be testing pathfinding, not the
    /// objective loop. Drive the player straight to the target instead.
    private func standOn(_ session: GameSession, x: Double, z: Double) {
        session.debugTeleport(x: x, z: z)
    }

    func testAFloorIsFinishable() throws {
        let session = GameSession(levelIndex: 0)
        XCTAssertEqual(session.tapes.count, GameSession.tapesPerFloor)
        XCTAssertEqual(session.tapesThisFloor, 0)
        let firstExit = try XCTUnwrap(session.exit)
        XCTAssertFalse(firstExit.revealed)

        // Take both tapes.
        for expected in 1...GameSession.tapesPerFloor {
            let tape = try XCTUnwrap(session.tapes.first { !$0.found })
            standOn(session, x: tape.x, z: tape.z)
            XCTAssertEqual(session.availableInteraction, .tape(index: tape.index),
                           "standing on a tape should offer it")
            session.interact(renderer: nil)
            XCTAssertEqual(session.tapesThisFloor, expected)
            XCTAssertEqual(session.tapesTotal, expected)
        }

        // The last one drags the door over and reveals it.
        let movedExit = try XCTUnwrap(session.exit)
        XCTAssertTrue(movedExit.revealed, "the last tape must reveal the door")
        let moveDistance = hypot(movedExit.x - firstExit.x, movedExit.z - firstExit.z)
        XCTAssertGreaterThan(moveDistance, 1, "the door never moved")
        XCTAssertNotNil(session.message)

        // Walk into it and open it.
        standOn(session, x: movedExit.x, z: movedExit.z)
        XCTAssertEqual(session.availableInteraction, .door)
        session.interact(renderer: nil)
        XCTAssertTrue(try XCTUnwrap(session.exit).opening)

        advance(session, seconds: 1.5)
        XCTAssertEqual(session.phase, .awaitingDescent,
                       "an opened door on floor 0 should hand off to the next floor")
    }

    /// The whole run: four floors, eight tapes, out the other side.
    func testTheWholeRunCanBeCompleted() throws {
        let session = GameSession(levelIndex: 0)
        for floor in 0..<LevelSpec.standardLevels.count {
            XCTAssertEqual(session.levelIndex, floor)
            for _ in 0..<GameSession.tapesPerFloor {
                let tape = try XCTUnwrap(session.tapes.first { !$0.found })
                standOn(session, x: tape.x, z: tape.z)
                session.interact(renderer: nil)
            }
            let exit = try XCTUnwrap(session.exit)
            standOn(session, x: exit.x, z: exit.z)
            session.interact(renderer: nil)
            advance(session, seconds: 1.5)

            if floor < LevelSpec.standardLevels.count - 1 {
                XCTAssertEqual(session.phase, .awaitingDescent, "floor \(floor) did not hand off")
                session.advanceToNextFloor(renderer: nil)
                XCTAssertEqual(session.phase, .transitioning)
                advance(session, seconds: GameSession.transitionLength + 0.2)
                XCTAssertEqual(session.phase, .playing, "the cut never ended")
            } else {
                XCTAssertEqual(session.phase, .escaped, "the last door should end the run")
            }
        }
        XCTAssertEqual(session.tapesTotal,
                       GameSession.tapesPerFloor * LevelSpec.standardLevels.count,
                       "tapes banked on earlier floors must carry down")
        XCTAssertEqual(session.levelIndex, LevelSpec.standardLevels.count - 1)
    }

    /// Dying gives back this floor's tapes but keeps what you banked above.
    func testDeathCostsOnlyTheCurrentFloorsTapes() throws {
        let session = GameSession(levelIndex: 0)
        for _ in 0..<GameSession.tapesPerFloor {
            let tape = try XCTUnwrap(session.tapes.first { !$0.found })
            standOn(session, x: tape.x, z: tape.z)
            session.interact(renderer: nil)
        }
        let exit = try XCTUnwrap(session.exit)
        standOn(session, x: exit.x, z: exit.z)
        session.interact(renderer: nil)
        advance(session, seconds: 1.5)
        session.advanceToNextFloor(renderer: nil)
        advance(session, seconds: GameSession.transitionLength + 0.2)
        XCTAssertEqual(session.tapesTotal, 2)

        // One tape into floor 1, then die.
        let tape = try XCTUnwrap(session.tapes.first { !$0.found })
        standOn(session, x: tape.x, z: tape.z)
        session.interact(renderer: nil)
        XCTAssertEqual(session.tapesTotal, 3)

        session.restart(renderer: nil)
        XCTAssertEqual(session.tapesTotal, 2, "floor 0's tapes should have survived the death")
        XCTAssertEqual(session.tapesThisFloor, 0)
        XCTAssertEqual(session.levelIndex, 1, "you restart the floor you died on")
    }

    func testTakingATapePullsTheHuntIn() throws {
        let session = GameSession(levelIndex: 0)
        let before = session.nextHunt
        let tape = try XCTUnwrap(session.tapes.first)
        standOn(session, x: tape.x, z: tape.z)
        session.interact(renderer: nil)
        XCTAssertLessThan(session.nextHunt, before, "a tape should be loud")
        XCTAssertLessThanOrEqual(session.nextHunt, 5)
    }

    /// The last tape pulls the hunt in *and* moves the door; without a window
    /// to run, the two together read as an unavoidable ambush.
    func testTheLastTapeBuysTimeToRunForTheDoor() throws {
        let session = GameSession(levelIndex: 0)
        for _ in 0..<GameSession.tapesPerFloor {
            let tape = try XCTUnwrap(session.tapes.first { !$0.found })
            standOn(session, x: tape.x, z: tape.z)
            session.interact(renderer: nil)
        }
        XCTAssertGreaterThanOrEqual(session.nextHunt, 11,
                                    "no window between the door moving and the hunt")
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
