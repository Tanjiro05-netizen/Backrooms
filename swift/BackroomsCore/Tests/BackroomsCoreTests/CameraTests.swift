import XCTest
@testable import BackroomsCore

/// Camera fixtures are view and projection matrices taken straight from the
/// shipping game's `THREE.PerspectiveCamera` across a spread of poses
/// (including steep pitch and non-16:9 aspects). If the native camera drifts
/// from these, the Metal renderer frames the world differently than the game
/// players already know — so this is parity, not just correctness.
final class CameraTests: XCTestCase {

    struct CamFixture: Decodable {
        let near: Float
        let far: Float
        let poses: [Entry]
        struct Entry: Decodable {
            let pose: Pose
            let view: [Float]
            let proj: [Float]
        }
        struct Pose: Decodable {
            let px: Float; let py: Float; let pz: Float
            let yaw: Float; let pitch: Float
            let fov: Float; let aspect: Float
        }
    }

    private func load() throws -> CamFixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/camera", withExtension: "json"))
        return try JSONDecoder().decode(CamFixture.self, from: Data(contentsOf: url))
    }

    func testMatricesMatchTheWebRenderer() throws {
        let fix = try load()
        // Magnitude-aware tolerance. A view matrix's translation column holds
        // world coordinates that reach into the hundreds of metres, and Float
        // resolution there is already ~1.5e-5 — so a flat absolute epsilon
        // would fail on arithmetic that is exactly right. Basis elements stay
        // in [-1, 1] and are still held to 1e-5.
        func tolerance(for expected: Float) -> Float {
            max(1e-5, abs(expected) * 1e-5)
        }
        for (i, entry) in fix.poses.enumerated() {
            let p = entry.pose
            let view = Mat4.view(positionX: p.px, y: p.py, z: p.pz,
                                 pitch: p.pitch, yaw: p.yaw, roll: 0)
            let proj = Mat4.perspectiveGL(fovDegrees: p.fov, aspect: p.aspect,
                                          near: fix.near, far: fix.far)
            for k in 0..<16 {
                XCTAssertEqual(view.m[k], entry.view[k],
                               accuracy: tolerance(for: entry.view[k]), "pose \(i) view[\(k)]")
                XCTAssertEqual(proj.m[k], entry.proj[k],
                               accuracy: tolerance(for: entry.proj[k]), "pose \(i) proj[\(k)]")
            }
        }
    }

    /// The Metal projection must frame identically to the GL one — same x/y
    /// scale — while mapping depth into [0, 1] instead of [-1, 1].
    func testMetalProjectionSharesFramingButRemapsDepth() {
        let gl = Mat4.perspectiveGL(fovDegrees: 72, aspect: 16.0/9.0, near: 0.08, far: 110)
        let mtl = Mat4.perspectiveMetal(fovDegrees: 72, aspect: 16.0/9.0, near: 0.08, far: 110)
        XCTAssertEqual(gl[0, 0], mtl[0, 0], accuracy: 1e-6)
        XCTAssertEqual(gl[1, 1], mtl[1, 1], accuracy: 1e-6)
        XCTAssertEqual(mtl[2, 3], -1, accuracy: 1e-6)

        // A point at the near plane maps to depth 0, at the far plane to 1.
        func depth(_ z: Float, _ m: Mat4) -> Float {
            let clipZ = m[2, 2] * z + m[3, 2]
            let clipW = -z
            return clipZ / clipW
        }
        XCTAssertEqual(depth(-0.08, mtl), 0, accuracy: 1e-4)
        XCTAssertEqual(depth(-110, mtl), 1, accuracy: 1e-4)
    }

    func testForwardVectorPointsWhereTheCameraLooks() {
        var cam = Camera()
        cam.pitch = 0
        // yaw 0 looks down −Z, which is how the game's spawn faces.
        cam.yaw = 0
        var f = cam.forward
        XCTAssertEqual(f.x, 0, accuracy: 1e-6)
        XCTAssertEqual(f.z, -1, accuracy: 1e-6)
        // A quarter turn looks down −X.
        cam.yaw = .pi / 2
        f = cam.forward
        XCTAssertEqual(f.x, -1, accuracy: 1e-6)
        XCTAssertEqual(f.z, 0, accuracy: 1e-6)
    }

    func testCameraFollowsThePlayerEye() {
        let map = GameMap.generate(spec: LevelSpec.standardLevels[0], levelIndex: 0)
        let sim = PlayerSim(map: map, colliders: [:])
        var cam = Camera()
        cam.follow(player: sim)
        XCTAssertEqual(cam.x, Float(sim.x), accuracy: 1e-5)
        XCTAssertEqual(cam.z, Float(sim.z), accuracy: 1e-5)
        XCTAssertEqual(cam.y, Camera.eyeHeight, accuracy: 1e-5)
    }
}
