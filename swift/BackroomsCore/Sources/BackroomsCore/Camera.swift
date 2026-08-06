import Foundation

/// The camcorder. Turns simulation state (where the player stands, where they
/// are looking, how wide the lens is) into the matrices a renderer uploads.
///
/// This is the seam between `BackroomsCore` and any renderer: the Metal layer
/// asks for `viewMatrix` / `projectionMatrix` and needs to know nothing about
/// how the game decided where to point.
public struct Camera: Sendable {
    /// Matches the web build's `EYE` — the operator's eye height in metres.
    public static let eyeHeight: Float = 1.62
    public static let baseFOV: Float = 72
    public static let sprintFOV: Float = 77.5
    public static let near: Float = 0.08
    public static let far: Float = 110

    public var x: Float = 0
    public var y: Float = Camera.eyeHeight
    public var z: Float = 0
    public var yaw: Float = -.pi / 2
    public var pitch: Float = 0
    /// Handheld bank — the lean the game applies when strafing or turning.
    public var roll: Float = 0
    public var fov: Float = Camera.baseFOV
    public var aspect: Float = 16.0 / 9.0

    public init() {}

    /// Place the camera at the player's eye, above whatever ground they stand
    /// on (the Poolrooms raise the floor onto platforms).
    public mutating func follow(player: PlayerSim, groundY: Float = 0) {
        x = Float(player.x)
        z = Float(player.z)
        y = groundY + Camera.eyeHeight
        yaw = Float(player.yaw)
    }

    public var viewMatrix: Mat4 {
        Mat4.view(positionX: x, y: y, z: z, pitch: pitch, yaw: yaw, roll: roll)
    }

    /// Metal depth convention (clip z in [0, 1]) — what the native renderer uses.
    public var projectionMatrix: Mat4 {
        Mat4.perspectiveMetal(fovDegrees: fov, aspect: aspect,
                              near: Camera.near, far: Camera.far)
    }

    /// OpenGL/Three.js depth convention (clip z in [-1, 1]) — used to verify
    /// framing parity against the shipping web renderer.
    public var projectionMatrixGL: Mat4 {
        Mat4.perspectiveGL(fovDegrees: fov, aspect: aspect,
                           near: Camera.near, far: Camera.far)
    }

    /// Combined view-projection, ready to hand to a vertex shader.
    public var viewProjection: Mat4 { projectionMatrix.multiplied(by: viewMatrix) }

    /// Unit forward vector (−Z rotated by the camera basis), which the AI uses
    /// to decide whether the player is looking at something.
    public var forward: (x: Float, y: Float, z: Float) {
        let r = Mat4.rotationYXZ(pitch: pitch, yaw: yaw, roll: roll)
        return (-r[2, 0], -r[2, 1], -r[2, 2])
    }
}
