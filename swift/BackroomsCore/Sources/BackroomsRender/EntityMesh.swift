import Foundation

/// Builds the hunter's silhouette as world-space triangles, rebuilt each frame.
///
/// The level shader takes no per-object model matrix — every level vertex is
/// already in world space — so rather than bolt one on for a single moving
/// object, the entity is re-emitted in world space per frame. It is a few
/// hundred vertices; the transform cost is noise next to the draw call, and it
/// keeps the shader and the vertex layout identical for everything on screen.
///
/// The shape is the web build's "eerie stickman": far too tall, limbs far too
/// thin, head far too small. It reads as a silhouette at fog distance, which is
/// the whole point — you should recognise it before you can resolve it.
public enum EntityMesh {

    /// Overall height in metres. Deliberately above human scale.
    public static let height: Float = 2.35

    /// One stickman, standing on `groundY`, facing `yaw` (same convention as the
    /// camera: yaw 0 looks down −Z). `phase` drives the walk cycle — pass the
    /// distance travelled so the stride tracks actual speed rather than time.
    public static func stickman(x: Float, groundY: Float, z: Float,
                                yaw: Float, phase: Float) -> InterleavedMesh {
        var v = [Float]()
        v.reserveCapacity(9 * 36 * InterleavedMesh.floatsPerVertex)

        let s = sinf(yaw), c = cosf(yaw)
        // Limbs swing in antiphase; arms trail the legs, which reads as a lope.
        let swing = sinf(phase * 2.6) * 0.34
        let armSwing = -swing * 0.8
        let bob = fabsf(sinf(phase * 2.6)) * 0.045

        let h = EntityMesh.height
        let hipY = h * 0.50 + bob
        let shoulderY = h * 0.84 + bob
        let headY = h * 0.93 + bob

        /// Emits an axis-aligned box in the entity's local frame, rotated into
        /// world space. `lean` tilts the box around its top edge, which is how
        /// the limbs swing without needing a real skeleton.
        func limb(cx: Float, top: Float, bottom: Float, halfW: Float, lean: Float) {
            let len = top - bottom
            let footOffset = sinf(lean) * len
            box(centerX: cx, centerY: (top + bottom) * 0.5,
                centerZ: footOffset * 0.5,
                halfX: halfW, halfY: len * 0.5, halfZ: halfW)
        }

        func box(centerX: Float, centerY: Float, centerZ: Float,
                 halfX: Float, halfY: Float, halfZ: Float) {
            let faces: [(n: (Float, Float, Float), corners: [(Float, Float, Float)])] = [
                ((0, 0, 1),  [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
                ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
                ((1, 0, 0),  [(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, -1, 1), (1, 1, -1), (1, 1, 1)]),
                ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, -1, -1), (-1, 1, 1), (-1, 1, -1)]),
                ((0, 1, 0),  [(-1, 1, 1), (1, 1, 1), (1, 1, -1), (-1, 1, 1), (1, 1, -1), (-1, 1, -1)]),
                ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, -1), (1, -1, 1), (-1, -1, 1)])
            ]
            for face in faces {
                // Rotate the normal about Y by the entity's heading.
                let nx = face.n.0 * c + face.n.2 * s
                let nz = -face.n.0 * s + face.n.2 * c
                for corner in face.corners {
                    let lx = centerX + corner.0 * halfX
                    let ly = centerY + corner.1 * halfY
                    let lz = centerZ + corner.2 * halfZ
                    let wx = x + (lx * c + lz * s)
                    let wz = z + (-lx * s + lz * c)
                    v.append(contentsOf: [wx, groundY + ly, wz,
                                          nx, face.n.1, nz,
                                          (corner.0 + 1) * 0.5, (corner.1 + 1) * 0.5])
                }
            }
        }

        let legHalf: Float = 0.048
        let armHalf: Float = 0.038
        limb(cx: -0.11, top: hipY, bottom: 0, halfW: legHalf, lean: swing)
        limb(cx: 0.11, top: hipY, bottom: 0, halfW: legHalf, lean: -swing)
        // Torso: a narrow slab, slightly deeper than it is wide.
        box(centerX: 0, centerY: (hipY + shoulderY) * 0.5, centerZ: 0,
            halfX: 0.115, halfY: (shoulderY - hipY) * 0.5, halfZ: 0.075)
        limb(cx: -0.17, top: shoulderY, bottom: hipY * 0.62, halfW: armHalf, lean: armSwing)
        limb(cx: 0.17, top: shoulderY, bottom: hipY * 0.62, halfW: armHalf, lean: -armSwing)
        // Neck, then a head too small for the body.
        box(centerX: 0, centerY: (shoulderY + headY) * 0.5, centerZ: 0,
            halfX: 0.032, halfY: (headY - shoulderY) * 0.5, halfZ: 0.032)
        box(centerX: 0, centerY: headY + 0.075, centerZ: 0,
            halfX: 0.085, halfY: 0.095, halfZ: 0.080)

        return InterleavedMesh(rawVertices: v)
    }
}
