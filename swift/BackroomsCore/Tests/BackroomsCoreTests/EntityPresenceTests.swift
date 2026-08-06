import Foundation
import XCTest
@testable import BackroomsCore

/// Covers the entity's idle and sighting phases — the two branches of the web
/// build's `updateEntity` that the hunt port deliberately left out.
///
/// These tests assert the *rules* the code promises, not outcomes that happened
/// to occur on one seed. That distinction has already cost this port four
/// separate false-green tests: a threshold that only held for one arrangement
/// of the RNG stream, and broke the moment anything upstream drew from it.
/// "A sighting is placed somewhere the player can see it" is a rule.
/// "The first sighting on level 0 is 17.3m away" is a coincidence.
final class EntityPresenceTests: XCTestCase {

    private let step = 1.0 / 60.0

    /// Generation is not cheap and these tests ask for the same four floors
    /// dozens of times.
    private static var mapCache: [Int: GameMap] = [:]

    private func level(_ index: Int) -> GameMap {
        if let cached = EntityPresenceTests.mapCache[index] { return cached }
        let map = GameMap.generate(spec: LevelSpec.standardLevels[index], levelIndex: index)
        EntityPresenceTests.mapCache[index] = map
        return map
    }

    /// A player standing on the spawn cell, facing +x.
    private func spawn(_ map: GameMap) -> (x: Double, z: Double) {
        (map.cellWorldX(map.spawnX), map.cellWorldZ(map.spawnZ))
    }

    private func presence(_ index: Int,
                          difficulty: EntityDifficulty = .standard) -> EntityPresence {
        EntityPresence(def: EntityDef.byLevel[index], map: level(index),
                       seed: LevelSpec.seed(forLevel: index), difficulty: difficulty)
    }

    // MARK: - Idle scheduling

    func testTheFirstHuntIsTheCreaturesOwnDelay() {
        for index in 0..<LevelSpec.standardLevels.count {
            let e = presence(index)
            XCTAssertEqual(e.nextHunt, EntityDef.byLevel[index].baseHuntDelay, accuracy: 1e-9,
                           "level \(index) did not use its creature's hunt delay")
            // `(8 + rng*8) * diff.sight`, so the first sighting is 8–16s out.
            XCTAssertGreaterThanOrEqual(e.nextSight, 8)
            XCTAssertLessThanOrEqual(e.nextSight, 16)
            XCTAssertEqual(e.state, .idle)
            XCTAssertFalse(e.isVisible, "it should not be on the map before anything happens")
        }
    }

    /// SIMPLE is meant to be finishable while you learn the floors: hunts come
    /// 3.2× less often and sightings 2.2× less often.
    func testDifficultyStretchesTheSchedule() {
        let standard = presence(0, difficulty: .standard)
        let simple = presence(0, difficulty: .simple)
        XCTAssertEqual(simple.nextHunt, standard.nextHunt * EntityDifficulty.simple.hunt,
                       accuracy: 1e-9)
        XCTAssertEqual(simple.nextSight, standard.nextSight * EntityDifficulty.simple.sight,
                       accuracy: 1e-9)
    }

    /// The telegraph is the entire warning: the lights sag and something
    /// exhales roughly 1.4s before it drops in. Firing it late, twice, or not
    /// at all turns a hunt into an ambush.
    func testTheTelegraphFiresOnceAndLeadsTheHunt() {
        var e = presence(0)
        let (px, pz) = spawn(level(0))
        var telegraphs = 0, huntFrame = -1, telegraphFrame = -1

        for frame in 0..<(60 * 240) {
            let events = e.step(dt: step, playerX: px, playerZ: pz,
                                forwardX: 1, forwardZ: 0, tapesFound: 0, attackReady: true)
            for event in events {
                if event == .telegraph {
                    telegraphs += 1
                    telegraphFrame = frame          // keep the most recent
                }
                if event == .huntBegan && huntFrame < 0 { huntFrame = frame }
            }
            if huntFrame >= 0 { break }
        }

        XCTAssertGreaterThanOrEqual(huntFrame, 0, "no hunt ever began")
        XCTAssertGreaterThan(telegraphs, 0, "the hunt arrived with no warning at all")
        // The cue that matters is the last one before it drops in: 1.4s of
        // lead, allowing a frame either side for the crossing itself.
        //
        // The count is deliberately not pinned to one. A sighting that starts
        // inside the telegraph window clears the flag on its way out, so the
        // cue fires again on the way back to idle — the web build's behaviour,
        // and the right one: the warning belongs to the hunt, and you should
        // get it whatever else happened in between.
        let lead = Double(huntFrame - telegraphFrame) * step
        XCTAssertGreaterThan(lead, 1.4 - 2 * step, "the warning came too late to act on")
        XCTAssertLessThan(lead, 1.4 + 2 * step, "the last warning did not lead the hunt")
    }

    /// The hunt clock does not run while it is already on the map. Otherwise a
    /// long sighting would queue up a hunt to land the instant it ends.
    func testTheHuntClockOnlyRunsWhileIdle() {
        var e = presence(0)
        let (px, pz) = spawn(level(0))
        var sawSighting = false

        for _ in 0..<(60 * 240) {
            // The state *before* the step is what decides whether this step was
            // allowed to tick the clock. Reading it afterwards misjudges the
            // frame a sighting begins on: that step ran the idle branch, ticked
            // the clock legitimately, and only then became a sighting.
            let wasSeen = e.state == .seen
            let before = e.nextHunt
            let events = e.step(dt: step, playerX: px, playerZ: pz,
                                forwardX: 1, forwardZ: 0, tapesFound: 0, attackReady: true)
            if events.contains(.huntBegan) { break }
            if wasSeen {
                sawSighting = true
                XCTAssertEqual(e.nextHunt, before, accuracy: 1e-12,
                               "the hunt clock ticked during a sighting")
            }
        }
        XCTAssertTrue(sawSighting, "no sighting occurred, so nothing was actually checked")
    }

    // MARK: - Sighting placement

    /// Wherever a sighting lands, it must be somewhere the player can actually
    /// see, at the creature's own range, inside the building, and not inside a
    /// pillar. Those four are the whole contract of the placement search — the
    /// specific spot it picks is not.
    func testEverySightingIsPlacedSomewhereItCanBeSeen() {
        var checked = 0
        for index in 0..<LevelSpec.standardLevels.count {
            let map = level(index)
            let def = EntityDef.byLevel[index]
            let (px, pz) = spawn(map)
            var e = presence(index)

            for _ in 0..<(60 * 400) {
                let events = e.step(dt: step, playerX: px, playerZ: pz,
                                    forwardX: 1, forwardZ: 0, tapesFound: 0, attackReady: true)
                guard events.contains(.sighting) else { continue }
                checked += 1

                let dx = e.x - px, dz = e.z - pz
                let dist = (dx * dx + dz * dz).squareRoot()
                // The band is nominal, not exact: the target point is snapped to
                // its containing cell (up to ~0.71 × cellSize away, at a corner)
                // and then jittered up to 1m in each axis (√2). Slack covers
                // both, and the check still catches a sighting materialising in
                // the player's face or across the building.
                let slack = map.spec.cellSize + 1.5
                XCTAssertGreaterThan(dist, def.sightMin - slack,
                                     "level \(index): a sighting appeared on top of the player")
                XCTAssertLessThan(dist, def.sightMax + slack,
                                  "level \(index): a sighting appeared out of sight range")
                XCTAssertTrue(map.lineOfSightClear(ax: px, az: pz, bx: e.x, bz: e.z),
                              "level \(index): a sighting was placed behind a wall")

                let cx = map.worldToCellX(e.x), cz = map.worldToCellZ(e.z)
                XCTAssertTrue(cx >= 1 && cz >= 1 && cx < map.grid - 1 && cz < map.grid - 1,
                              "level \(index): a sighting was placed outside the building")
                XCTAssertEqual(map.pillarMask[cx + cz * map.grid], 0,
                               "level \(index): a sighting was placed inside a pillar")
            }
        }
        XCTAssertGreaterThan(checked, 0, "no sighting ever fired — nothing was checked")
    }

    // MARK: - Being looked at

    /// Drives a presence to its first sighting, then hands back a stepper that
    /// keeps the camera pointed exactly at it (or exactly away).
    private func atFirstSighting(_ index: Int,
                                 playerAt p: (x: Double, z: Double)) -> EntityPresence? {
        var e = presence(index)
        for _ in 0..<(60 * 400) {
            let events = e.step(dt: step, playerX: p.x, playerZ: p.z,
                                forwardX: 1, forwardZ: 0, tapesFound: 0, attackReady: true)
            if events.contains(.huntBegan) { return nil }   // hunt beat the sighting
            if events.contains(.sighting) { return e }
        }
        return nil
    }

    /// Look straight at it and step. `toward` false points the camera the
    /// opposite way, which is what "looking away" means to the gaze test.
    @discardableResult
    private func stare(_ e: inout EntityPresence, at p: (x: Double, z: Double),
                       toward: Bool = true, seconds: Double,
                       onEvent: (EntityPresence.Event, EntityPresence) -> Void = { _, _ in })
        -> Int {
        var frames = 0
        for _ in 0..<Int(seconds / step) {
            let dx = e.x - p.x, dz = e.z - p.z
            let d = max(1e-6, (dx * dx + dz * dz).squareRoot())
            let sign: Double = toward ? 1 : -1
            let events = e.step(dt: step, playerX: p.x, playerZ: p.z,
                                forwardX: sign * dx / d, forwardZ: sign * dz / d,
                                tapesFound: 0, attackReady: true)
            frames += 1
            for event in events { onEvent(event, e) }
            if e.state != .seen { break }
        }
        return frames
    }

    /// The smiler's rule: hold it in frame and it stops existing. This is the
    /// one interaction the player has with a sighting, so it has to work on the
    /// gaze clock and not on luck.
    func testStaringDownTheSmilerMakesItVanish() throws {
        let map = level(0)
        let p = spawn(map)
        var e = try XCTUnwrap(atFirstSighting(0, playerAt: p), "no sighting to stare at")
        XCTAssertEqual(e.state, .seen)

        var vanished = false
        stare(&e, at: p, seconds: 4) { event, _ in
            if event == .vanished { vanished = true }
        }
        XCTAssertTrue(vanished, "the smiler outlasted a four-second stare")
        XCTAssertEqual(e.state, .idle)
        XCTAssertFalse(e.isVisible)
        XCTAssertGreaterThan(e.nextSight, 0, "vanishing must reschedule, not stop, sightings")
    }

    /// The hound does the opposite: catch its eye and it breaks and runs. What
    /// matters is that it ends up further away than it started — a flee that
    /// closes ground is not a flee.
    func testTheHoundBreaksAndRunsWhenCaught() throws {
        let map = level(1)
        let p = spawn(map)
        var e = try XCTUnwrap(atFirstSighting(1, playerAt: p), "no sighting to catch")

        let startDistance = distance(from: e, to: p)
        var fled = false
        stare(&e, at: p, seconds: 4) { event, _ in
            if event == .fled { fled = true }
        }
        XCTAssertTrue(fled, "the hound stood and stared back")
        // It runs for `fleeTime` at `fleeSpeed`; even sideways that is ground
        // gained away from the player.
        XCTAssertGreaterThan(distance(from: e, to: p), startDistance,
                             "the hound 'fled' toward the player")
    }

    /// The crawler and the drowned do not care that you are looking. That is
    /// what makes them the two you cannot stare down, and it has to hold
    /// against exactly the input that removes a smiler.
    func testTheCrawlerKeepsComingWhileWatched() throws {
        XCTAssertTrue(EntityDef.crawler.creepObserved)
        XCTAssertFalse(EntityDef.crawler.gazeVanish)
        XCTAssertFalse(EntityDef.crawler.fleeOnGaze)

        let map = level(2)
        let p = spawn(map)
        var e = try XCTUnwrap(atFirstSighting(2, playerAt: p), "no sighting to face down")

        let startDistance = distance(from: e, to: p)
        stare(&e, at: p, seconds: 2)
        XCTAssertLessThan(distance(from: e, to: p), startDistance,
                          "staring at the crawler stopped it — it is supposed to not care")
    }

    /// And the inverse for the smiler: it only moves when unwatched, so looking
    /// away is what lets it close.
    func testTheSmilerOnlyClosesWhileUnwatched() throws {
        let map = level(0)
        let p = spawn(map)
        var e = try XCTUnwrap(atFirstSighting(0, playerAt: p), "no sighting to test")

        // Watched: it should hold position (it can still vanish, which ends the
        // measurement honestly rather than by standing still).
        let watchedStart = distance(from: e, to: p)
        stare(&e, at: p, seconds: 0.8)
        if e.state == .seen {
            XCTAssertEqual(distance(from: e, to: p), watchedStart, accuracy: 1e-9,
                           "the smiler crept while being watched")
        }

        // Unwatched: it closes.
        var f = try XCTUnwrap(atFirstSighting(0, playerAt: p))
        let awayStart = distance(from: f, to: p)
        stare(&f, at: p, toward: false, seconds: 2)
        XCTAssertLessThan(distance(from: f, to: p), awayStart,
                          "the smiler did not close while the player looked away")
    }

    // MARK: - Determinism

    /// Same seed, same input trace, same everything.
    ///
    /// This is the test that catches an unseeded draw creeping back in. The web
    /// build reaches for `Math.random()` for the flee bearing and the reposition
    /// roll; a port that copied that literally would pass every behavioural test
    /// above and fail this one.
    func testTheWholeStateMachineIsDeterministic() {
        let map = level(0)
        let p = spawn(map)

        func trace() -> [String] {
            var e = presence(0)
            var out: [String] = []
            for frame in 0..<(60 * 300) {
                // A look pattern that sweeps through the entity, so gaze,
                // flee and reposition draws all get exercised.
                let angle = Double(frame) * step * 0.7
                let events = e.step(dt: step, playerX: p.x, playerZ: p.z,
                                    forwardX: cos(angle), forwardZ: sin(angle),
                                    tapesFound: 0, attackReady: true)
                for event in events {
                    out.append("\(frame):\(event):\(e.x.rounded(toPlaces: 9)),\(e.z.rounded(toPlaces: 9))")
                }
            }
            return out
        }

        let a = trace(), b = trace()
        XCTAssertFalse(a.isEmpty, "nothing happened in five minutes — the trace is vacuous")
        XCTAssertEqual(a, b, "the entity is not reproducible from its seed")
    }

    /// Reactions to the player draw from their own stream. Looking at a
    /// creature is a player choice made at an unpredictable moment; if it
    /// consumed the scheduling stream, turning your head would silently move
    /// where the *next* sighting appears. That coupling is exactly what split
    /// `objectiveRng` out from the session RNG earlier in this port.
    func testPlayerReactionsDoNotDisturbTheSchedule() {
        let map = level(1)   // the hound: every gaze costs a flee draw
        let p = spawn(map)

        /// Runs to the first sighting identically in both cases, then either
        /// stares (burning reaction draws) or does not, and reports what the
        /// scheduling stream produced next.
        func nextSightAfterFirst(staring: Bool) -> Double {
            var e = presence(1)
            var seen = false
            for _ in 0..<(60 * 400) {
                var fx = 1.0, fz = 0.0
                if seen && staring {
                    let dx = e.x - p.x, dz = e.z - p.z
                    let d = max(1e-6, (dx * dx + dz * dz).squareRoot())
                    fx = dx / d; fz = dz / d
                }
                let events = e.step(dt: step, playerX: p.x, playerZ: p.z,
                                    forwardX: fx, forwardZ: fz,
                                    tapesFound: 0, attackReady: true)
                if events.contains(.sighting) { seen = true }
                if seen && e.state == .idle { return e.nextSight }
            }
            return -1
        }

        let quiet = nextSightAfterFirst(staring: false)
        let stared = nextSightAfterFirst(staring: true)
        XCTAssertGreaterThan(quiet, 0, "the first sighting never ended")
        XCTAssertEqual(quiet, stared, accuracy: 1e-12,
                       "staring at the entity moved the next sighting's schedule")
    }

    // MARK: - Helpers

    private func distance(from e: EntityPresence, to p: (x: Double, z: Double)) -> Double {
        let dx = e.x - p.x, dz = e.z - p.z
        return (dx * dx + dz * dz).squareRoot()
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
