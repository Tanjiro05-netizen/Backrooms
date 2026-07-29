import XCTest
@testable import BackroomsCore

/// Covers tape and exit placement and the interaction rules — the parts of the
/// game loop that decide whether a floor is finishable at all.
final class ObjectiveTests: XCTestCase {

    private func map(_ level: Int) -> GameMap {
        GameMap.generate(spec: LevelSpec.standardLevels[level], levelIndex: level)
    }

    private func rng(_ level: Int) -> Mulberry32 {
        Mulberry32(seed: LevelSpec.seed(forLevel: level) &+ 5387)
    }

    // MARK: - Tapes

    /// The floor is unfinishable if a tape lands inside a pillar or outside the
    /// walls, and unfair if one spawns in the room you start in.
    func testTapesLandSomewhereReachableAndNotOnTopOfSpawn() {
        for level in 0..<LevelSpec.standardLevels.count {
            let m = map(level)
            var r = rng(level)
            let tapes = Objectives.placeTapes(map: m, count: 2, rng: &r)
            XCTAssertEqual(tapes.count, 2, "level \(level) dropped a tape")

            let dist = m.distanceField(fromX: m.spawnX, z: m.spawnZ)
            let half = Double(m.grid) * m.spec.cellSize / 2
            for tape in tapes {
                let cx = m.worldToCellX(tape.x), cz = m.worldToCellZ(tape.z)
                guard (0..<m.grid).contains(cx), (0..<m.grid).contains(cz) else {
                    XCTFail("level \(level) tape \(tape.index) is outside the grid")
                    continue
                }
                XCTAssertLessThan(abs(tape.x), half)
                XCTAssertLessThan(abs(tape.z), half)
                let d = dist[cx + cz * m.grid]
                XCTAssertGreaterThanOrEqual(d, 0,
                    "level \(level) tape \(tape.index) is walled off from spawn")
                // Jitter can nudge a tape one cell in from its chosen cell, so
                // allow a little slack under the placement minimum.
                XCTAssertGreaterThanOrEqual(d, Objectives.minSpawnDistance - 2,
                    "level \(level) tape \(tape.index) spawned nearly on top of the player")
            }
        }
    }

    /// One per angular sector: two tapes must not end up in the same direction,
    /// or the floor is a straight line out and back.
    func testTapesAreSpreadAroundSpawn() {
        for level in 0..<LevelSpec.standardLevels.count {
            let m = map(level)
            var r = rng(level)
            let tapes = Objectives.placeTapes(map: m, count: 2, rng: &r)
            let sx = m.cellWorldX(m.spawnX), sz = m.cellWorldZ(m.spawnZ)
            let bearings = tapes.map { atan2($0.z - sz, $0.x - sx) }
            var separation = abs(bearings[0] - bearings[1])
            if separation > .pi { separation = 2 * .pi - separation }
            XCTAssertGreaterThan(separation, 0.6,
                "level \(level) put both tapes in the same direction")
        }
    }

    func testPoolTapesStayOutOfTheWater() {
        let m = map(3)                      // Level 37, the Poolrooms
        var r = rng(3)
        for tape in Objectives.placeTapes(map: m, count: 2, rng: &r) {
            let cx = m.worldToCellX(tape.x), cz = m.worldToCellZ(tape.z)
            XCTAssertEqual(m.zoneMask[cx + cz * m.grid], 0,
                           "a tape was dropped in the pool where it cannot be seen")
        }
    }

    func testTapePlacementIsDeterministic() {
        let m = map(0)
        var a = rng(0), b = rng(0)
        XCTAssertEqual(Objectives.placeTapes(map: m, count: 2, rng: &a),
                       Objectives.placeTapes(map: m, count: 2, rng: &b))
    }

    // MARK: - Exit

    /// The door starts at the far end. If it were merely "far", a floor could
    /// hand you the exit next door.
    func testExitStartsAtTheFurthestReachableCell() {
        for level in 0..<LevelSpec.standardLevels.count {
            let m = map(level)
            let exit = Objectives.placeExitFar(map: m)
            let dist = m.distanceField(fromX: m.spawnX, z: m.spawnZ)
            let cx = m.worldToCellX(exit.x), cz = m.worldToCellZ(exit.z)
            let here = dist[cx + cz * m.grid]
            var maxReachable: Int16 = 0
            for z in 1..<(m.grid - 1) {
                for x in 1..<(m.grid - 1) where m.pillarMask[x + z * m.grid] == 0 {
                    maxReachable = max(maxReachable, dist[x + z * m.grid])
                }
            }
            XCTAssertEqual(here, maxReachable, "level \(level) exit is not at the far end")
            XCTAssertGreaterThan(here, 10, "level \(level) exit is suspiciously close to spawn")
            XCTAssertFalse(exit.revealed, "the exit should start unfound")
        }
    }

    /// The last tape drags the door to within 2–4 rooms. Too far and the reward
    /// is another hike; too close and it lands in your lap.
    func testRelocatedExitArrivesTwoToFourRoomsAway() {
        for level in 0..<LevelSpec.standardLevels.count {
            let m = map(level)
            var r = rng(level)
            let px = m.cellWorldX(m.spawnX), pz = m.cellWorldZ(m.spawnZ)
            guard let moved = Objectives.relocatedExit(map: m, playerX: px, playerZ: pz,
                                                       rng: &r) else {
                XCTFail("level \(level) found nowhere to move the door")
                continue
            }
            let dist = m.distanceField(fromX: m.spawnX, z: m.spawnZ)
            let cx = m.worldToCellX(moved.x), cz = m.worldToCellZ(moved.z)
            let d = dist[cx + cz * m.grid]
            XCTAssertGreaterThanOrEqual(d, 2, "level \(level) door landed in the player's lap")
            XCTAssertLessThanOrEqual(d, 4, "level \(level) door landed too far to be a reward")
            XCTAssertEqual(m.pillarMask[cx + cz * m.grid], 0, "door moved inside a pillar")
        }
    }

    // MARK: - Interaction

    private func tape(at x: Double, _ z: Double, index: Int = 0) -> Objectives.Tape {
        Objectives.Tape(index: index, x: x, z: z, yaw: 0)
    }

    func testTapeIsTakeableWhenLookedAtAndInReach() {
        let t = tape(at: 0, -2)          // 2m straight ahead (yaw 0 looks down −Z)
        let action = Objectives.findInteraction(tapes: [t], exit: nil,
                                                playerX: 0, playerZ: 0,
                                                forwardX: 0, forwardZ: -1)
        XCTAssertEqual(action, .tape(index: 0))
    }

    func testTapeIsNotTakeableFromTooFarOrFacingAway() {
        let far = tape(at: 0, -4)
        XCTAssertNil(Objectives.findInteraction(tapes: [far], exit: nil,
                                                playerX: 0, playerZ: 0,
                                                forwardX: 0, forwardZ: -1),
                     "reach is \(Objectives.tapeReach)m; 4m should be out")

        let behind = tape(at: 0, -2)
        XCTAssertNil(Objectives.findInteraction(tapes: [behind], exit: nil,
                                                playerX: 0, playerZ: 0,
                                                forwardX: 0, forwardZ: 1),
                     "facing the other way should not pick it up")
    }

    /// Standing on it, facing stops mattering — otherwise you can end up unable
    /// to take a tape that is literally under you.
    func testTapeUnderfootIsTakeableFromAnyFacing() {
        let underfoot = tape(at: 0, -0.4)
        XCTAssertEqual(Objectives.findInteraction(tapes: [underfoot], exit: nil,
                                                  playerX: 0, playerZ: 0,
                                                  forwardX: 0, forwardZ: 1),
                       .tape(index: 0))
    }

    func testFoundTapesAreIgnored() {
        var t = tape(at: 0, -1)
        t.found = true
        XCTAssertNil(Objectives.findInteraction(tapes: [t], exit: nil,
                                                playerX: 0, playerZ: 0,
                                                forwardX: 0, forwardZ: -1))
    }

    /// In a doorway with a tape at your feet, you meant the door.
    func testDoorOutranksATapeAtTheSameSpot() {
        let t = tape(at: 0, -1.2)
        let exit = Objectives.Exit(x: 0, z: -1.2)
        XCTAssertEqual(Objectives.findInteraction(tapes: [t], exit: exit,
                                                  playerX: 0, playerZ: 0,
                                                  forwardX: 0, forwardZ: -1),
                       .door)
    }

    func testAnOpeningDoorStopsOfferingItself() {
        var exit = Objectives.Exit(x: 0, z: -1.2)
        exit.opening = true
        XCTAssertNil(Objectives.findInteraction(tapes: [], exit: exit,
                                                playerX: 0, playerZ: 0,
                                                forwardX: 0, forwardZ: -1))
    }

    func testNearestOfTwoTapesWins() {
        let near = tape(at: 0, -1, index: 5)
        let far = tape(at: 0, -2.2, index: 6)
        XCTAssertEqual(Objectives.findInteraction(tapes: [far, near], exit: nil,
                                                  playerX: 0, playerZ: 0,
                                                  forwardX: 0, forwardZ: -1),
                       .tape(index: 5))
    }
}
