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

        init(phase: Float) {
            let t = phase * 2.6
            swing = sinf(t) * 0.34
            armSwing = -sinf(t) * 0.34 * 0.8
            bob = fabsf(sinf(t)) * 0.045
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
    public static func silhouette(x: Float, groundY: Float, z: Float,
                                  yaw: Float, phase: Float) -> InterleavedMesh {
        var b = MeshBuilder(reservingVertices: silhouetteVertexCount)
        let g = Gait(phase: phase)
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
        let hipY = h * 0.50 + g.bob
        let shoulderY = h * 0.855 + g.bob

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
        let chest = p(g.sway, shoulderY, -0.06)
        bone(pelvis, chest, 0.105, 10, 3)

        // Neck, craned further forward than the chest.
        let neckTop = p(g.sway, h * 0.925 + g.bob, -0.115)
        bone(chest, neckTop, 0.036, 6, 2)

        // A head too small for the body, and set forward of the shoulders.
        let head = p(g.sway * 1.2, h * 0.955 + g.bob, -0.135)
        b.addSphere(originX: head.x, originY: head.y, originZ: head.z, yaw: yaw,
                    localX: 0, localY: 0, localZ: 0,
                    radius: 0.085, heightRadius: 0.105, segments: 10, rings: 6)

        return b.mesh
    }
}
