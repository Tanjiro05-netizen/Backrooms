import Foundation
import BackroomsCore

/// Builds the hunter's silhouette as world-space triangles, rebuilt each frame.
///
/// The level shader takes no per-object model matrix — every level vertex is
/// already in world space — so rather than bolt one on for a single moving
/// object, the entity is re-emitted in world space per frame. It is a couple of
/// thousand vertices at most; the transform cost is noise next to the draw
/// call, and it keeps the shader and the vertex layout identical for everything
/// on screen.
///
/// The shape is the web build's "eerie stickman": far too tall, limbs far too
/// thin, head far too small. It reads as a silhouette at fog distance, which is
/// the whole point — you should recognise it before you can resolve it.
public enum EntityMesh {

    /// Overall height in metres. Deliberately above human scale.
    public static let height: Float = 2.35

    /// Seven boxes: two legs, torso, two arms, neck, head.
    public static let boxCount = 7

    // MARK: - Shared pose

    /// The walk cycle, so both silhouettes lope in step.
    ///
    /// `phase` is distance travelled rather than time, so the stride tracks
    /// actual speed — a hunter that slows down takes shorter steps instead of
    /// moonwalking.
    private struct Gait {
        let swing: Float        // leg swing, radians
        let armSwing: Float     // arms trail the legs, which reads as a lope
        let bob: Float          // vertical rise and fall of the hips
        let sway: Float         // slow lateral drift of the spine

        /// `motion` is 0 for a thing standing perfectly still and 1 for a
        /// full run. A sighting that keeps swinging its legs on the spot is
        /// the single most immersion-breaking thing a creature can do.
        init(phase: Float, motion: Float = 1) {
            let t = phase * 2.6
            let m = max(0, min(1, motion))
            swing = sinf(t) * 0.34 * m
            armSwing = -sinf(t) * 0.34 * 0.8 * m
            bob = fabsf(sinf(t)) * 0.045 * m
            // Deliberately not a harmonic of the stride: a sway that lined up
            // with the steps would read as a march.
            sway = sinf(phase * 1.3) * 0.030
        }
    }

    // MARK: - Boxes

    /// One stickman, standing on `groundY`, facing `yaw` (same convention as the
    /// camera: yaw 0 looks down −Z). `phase` drives the walk cycle — pass the
    /// distance travelled so the stride tracks actual speed rather than time.
    ///
    /// Seven boxes, and it has to stay seven: this is what ships in the frame
    /// budget on the oldest supported device. What was tuned here is the pose,
    /// not the count — arms that hang past the knee, a spine pitched forward and
    /// a head craned further forward still. A glimpse of that reads as wrong
    /// before you have resolved a single edge, which is the whole job.
    public static func stickman(x: Float, groundY: Float, z: Float,
                                yaw: Float, phase: Float) -> InterleavedMesh {
        var b = MeshBuilder(reservingBoxes: boxCount)
        let g = Gait(phase: phase)

        let h = EntityMesh.height
        let hipY = h * 0.50 + g.bob
        let shoulderY = h * 0.855 + g.bob
        let headY = h * 0.93 + g.bob

        /// A limb as a vertical box displaced along Z by its swing. Crude next
        /// to a real skeleton, but at fog distance the stride is all that reads.
        func limb(cx: Float, top: Float, bottom: Float, halfW: Float, lean: Float) {
            let len = top - bottom
            b.addBox(originX: x, originY: groundY, originZ: z, yaw: yaw,
                     localX: cx, localY: (top + bottom) * 0.5,
                     localZ: sinf(lean) * len * 0.5,
                     halfX: halfW, halfY: len * 0.5, halfZ: halfW)
        }

        let legHalf: Float = 0.048
        let armHalf: Float = 0.034
        limb(cx: -0.11, top: hipY, bottom: 0, halfW: legHalf, lean: g.swing)
        limb(cx: 0.11, top: hipY, bottom: 0, halfW: legHalf, lean: -g.swing)
        // Torso: a narrow slab, deeper than it is wide, pitched forward.
        b.addBox(originX: x, originY: groundY, originZ: z, yaw: yaw,
                 localX: g.sway, localY: (hipY + shoulderY) * 0.5, localZ: -0.05,
                 halfX: 0.098, halfY: (shoulderY - hipY) * 0.5, halfZ: 0.082)
        // Arms reaching to mid-shin. The single most legible wrong thing about
        // it at a distance where nothing else resolves.
        limb(cx: -0.175, top: shoulderY, bottom: hipY * 0.30, halfW: armHalf, lean: g.armSwing)
        limb(cx: 0.175, top: shoulderY, bottom: hipY * 0.30, halfW: armHalf, lean: -g.armSwing)
        // Neck, craned forward, then a head too small for the body.
        b.addBox(originX: x, originY: groundY, originZ: z, yaw: yaw,
                 localX: g.sway, localY: (shoulderY + headY) * 0.5, localZ: -0.07,
                 halfX: 0.030, halfY: (headY - shoulderY) * 0.5, halfZ: 0.030)
        b.addBox(originX: x, originY: groundY, originZ: z, yaw: yaw,
                 localX: g.sway, localY: headY + 0.070, localZ: -0.12,
                 halfX: 0.078, halfY: 0.092, halfZ: 0.074)

        return b.mesh
    }

    // MARK: - Round limbs

    /// What `silhouette` emits, so a caller can check it against the renderer's
    /// per-frame scratch buffer before switching to it.
    public static let silhouetteVertexCount =
        8 * MeshBuilder.verticesPerCapsule(segments: 8, rings: 2)
        + MeshBuilder.verticesPerCapsule(segments: 10, rings: 3)
        + MeshBuilder.verticesPerCapsule(segments: 6, rings: 2)
        + MeshBuilder.verticesPerSphere(segments: 10, rings: 6)

    /// The same creature with tapered, jointed limbs instead of boxes.
    ///
    /// A box limb can only fake a swing by sliding along Z — the yaw-only frame
    /// cannot tilt one — so the stickman's legs translate rather than rotate,
    /// and it cannot bend a knee at all. These are capsules between two points,
    /// so the knee and the elbow are real joints and the lope is an actual
    /// stride. Against a lit corridor that is the difference between a shape
    /// that is walking and a shape that is being dragged.
    ///
    /// Drop-in for `stickman`: same signature, same pose, same ground contact.
    /// - Parameters:
    ///   - motion: 0 standing, 1 running. Scales the whole stride.
    ///   - crouch: 0 upright, 1 fully hunched. A thing that is creeping toward
    ///     you carries itself differently from one that is sprinting at you,
    ///     and the posture reads at a distance where the stride does not.
    ///   - headTurn: radians the head is turned off the body's facing. This is
    ///     what makes a sighting feel like it is watching rather than merely
    ///     pointing — the body can be square to a wall while the head is not.
    public static func silhouette(x: Float, groundY: Float, z: Float,
                                  yaw: Float, phase: Float,
                                  motion: Float = 1, crouch: Float = 0,
                                  headTurn: Float = 0) -> InterleavedMesh {
        var b = MeshBuilder(reservingVertices: silhouetteVertexCount)
        let g = Gait(phase: phase, motion: motion)
        let hunch = max(0, min(1, crouch))
        let c = cosf(yaw), s = sinf(yaw)

        /// Local (right, up, forward-is-−Z) to world, matching `addBox`.
        func p(_ lx: Float, _ ly: Float, _ lz: Float) -> (x: Float, y: Float, z: Float) {
            (x: x + (lx * c + lz * s), y: groundY + ly, z: z + (-lx * s + lz * c))
        }
        func bone(_ a: (x: Float, y: Float, z: Float), _ d: (x: Float, y: Float, z: Float),
                  _ radius: Float, _ segments: Int, _ rings: Int) {
            b.addCapsuleBetween(ax: a.x, ay: a.y, az: a.z,
                                bx: d.x, by: d.y, bz: d.z,
                                radius: radius, segments: segments, rings: rings)
        }

        let h = EntityMesh.height
        // Hunching drops the whole frame and pitches it forward; the shoulders
        // fall further than the hips, which is what folds the spine over.
        let hipY = h * 0.50 + g.bob - hunch * 0.10
        let shoulderY = h * 0.855 + g.bob - hunch * 0.20
        let lean = hunch * 0.16

        for side in [Float(-1), 1] {
            // Legs. The foot swings fore and aft; the knee leads it, which is
            // what makes the stride read as a stride and not a scissor.
            let legLean = sinf(g.swing * side) * 0.62
            let footY: Float = 0.055
            let hip = p(side * 0.095, hipY, 0)
            let foot = p(side * 0.10, footY, legLean)
            let knee = p(side * 0.0975, (hipY + footY) * 0.5 + 0.02,
                         legLean * 0.5 - 0.085)
            bone(hip, knee, 0.050, 8, 2)
            bone(knee, foot, 0.040, 8, 2)

            // Arms, hanging to mid-shin, elbows barely bent.
            let armLean = sinf(g.armSwing * side) * 0.55
            let handY = hipY * 0.30
            let shoulder = p(side * 0.145, shoulderY - 0.02, -0.01)
            let hand = p(side * 0.20, handY, armLean)
            let elbow = p(side * 0.185, (shoulderY + handY) * 0.5,
                          armLean * 0.5 - 0.030)
            bone(shoulder, elbow, 0.040, 8, 2)
            bone(elbow, hand, 0.032, 8, 2)
        }

        // Spine, pitched forward from the pelvis to the chest.
        let pelvis = p(g.sway, hipY - 0.02, 0.02)
        let chest = p(g.sway, shoulderY, -0.06 - lean)
        bone(pelvis, chest, 0.105, 10, 3)

        // Neck, craned further forward than the chest.
        let neckTop = p(g.sway, h * 0.925 + g.bob - hunch * 0.22, -0.115 - lean * 1.3)
        bone(chest, neckTop, 0.036, 6, 2)

        // A head too small for the body, set forward of the shoulders, and
        // turned off the body's facing when it is watching you.
        let turn = max(-1.3, min(1.3, headTurn))
        let head = p(g.sway * 1.2 + sinf(turn) * 0.045,
                     h * 0.955 + g.bob - hunch * 0.24,
                     -0.135 - lean * 1.3 - (1 - cosf(turn)) * 0.03)
        b.addSphere(originX: head.x, originY: head.y, originZ: head.z, yaw: yaw + turn,
                    localX: 0, localY: 0, localZ: 0,
                    radius: 0.085, heightRadius: 0.105, segments: 10, rings: 6)

        return b.mesh
    }
}
