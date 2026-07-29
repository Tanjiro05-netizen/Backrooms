import Foundation
import BackroomsCore

/// The objectives, as geometry.
///
/// Split into a dark pass and a bright pass because a cassette lying on brown
/// carpet and a doorway that has to be spotted from across a room want opposite
/// treatments — and one texture is bound per draw.
public enum PropMesh {

    /// A VHS cassette: the web build's 0.30 × 0.055 × 0.18 box, lying flat.
    public static let tapeHalf = (x: Float(0.15), y: Float(0.0275), z: Float(0.09))

    public static let doorWidth: Float = 1.30
    public static let doorHeight: Float = 2.20
    private static let jamb: Float = 0.13
    private static let depth: Float = 0.14

    /// Everything drawn near-black: the cassette bodies and the void inside the
    /// doorway.
    public static func dark(tapes: [Objectives.Tape], exit: Objectives.Exit?,
                            groundY: (Double, Double) -> Double) -> InterleavedMesh {
        var b = MeshBuilder(reservingBoxes: tapes.count + 1)
        for tape in tapes where !tape.found {
            let gy = Float(groundY(tape.x, tape.z))
            b.addBox(originX: Float(tape.x), originY: gy, originZ: Float(tape.z),
                     yaw: Float(tape.yaw),
                     localX: 0, localY: tapeHalf.y + 0.01, localZ: 0,
                     halfX: tapeHalf.x, halfY: tapeHalf.y, halfZ: tapeHalf.z)
        }
        if let exit {
            // The void reads as depth behind the frame — a door that goes
            // somewhere, rather than a rectangle painted on a wall.
            let gy = Float(groundY(exit.x, exit.z))
            let inner = doorWidth / 2 - jamb
            b.addBox(originX: Float(exit.x), originY: gy, originZ: Float(exit.z), yaw: 0,
                     localX: 0, localY: doorHeight / 2, localZ: -depth,
                     halfX: inner, halfY: doorHeight / 2 - jamb / 2, halfZ: 0.04)
        }
        return b.mesh
    }

    /// Everything drawn bright: the door frame, and a small riser under each
    /// tape so a black cassette on a dark floor still catches the eye.
    public static func bright(tapes: [Objectives.Tape], exit: Objectives.Exit?,
                              groundY: (Double, Double) -> Double) -> InterleavedMesh {
        var b = MeshBuilder(reservingBoxes: tapes.count + 3)
        for tape in tapes where !tape.found {
            let gy = Float(groundY(tape.x, tape.z))
            // The spine label, standing just proud of the cassette body.
            b.addBox(originX: Float(tape.x), originY: gy, originZ: Float(tape.z),
                     yaw: Float(tape.yaw),
                     localX: 0, localY: tapeHalf.y * 2 + 0.012, localZ: 0,
                     halfX: tapeHalf.x * 0.62, halfY: 0.004, halfZ: tapeHalf.z * 0.5)
        }
        if let exit {
            let gy = Float(groundY(exit.x, exit.z))
            let half = doorWidth / 2
            // Two posts and a lintel. The door swings on `openTime`, but the
            // frame never moves, so it is the thing you actually navigate to.
            for side in [Float(-1), 1] {
                b.addBox(originX: Float(exit.x), originY: gy, originZ: Float(exit.z), yaw: 0,
                         localX: side * (half - jamb / 2), localY: doorHeight / 2, localZ: 0,
                         halfX: jamb / 2, halfY: doorHeight / 2, halfZ: depth)
            }
            b.addBox(originX: Float(exit.x), originY: gy, originZ: Float(exit.z), yaw: 0,
                     localX: 0, localY: doorHeight - jamb / 2, localZ: 0,
                     halfX: half, halfY: jamb / 2, halfZ: depth)
        }
        return b.mesh
    }
}
