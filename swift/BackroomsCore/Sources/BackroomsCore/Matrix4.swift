import Foundation

/// A 4×4 matrix stored **column-major**, the same layout as Three.js
/// `Matrix4.elements` and Metal's `simd_float4x4`. Keeping one layout end to
/// end means the fixtures dumped from the web renderer can be compared
/// element-for-element against what the native renderer will upload.
public struct Mat4: Equatable, Sendable {
    /// Column-major: `m[0...3]` is column 0, `m[4...7]` column 1, and so on,
    /// so `m[col * 4 + row]` addresses an element.
    public var m: [Float]

    public init(_ elements: [Float]) {
        precondition(elements.count == 16, "Mat4 needs 16 elements")
        self.m = elements
    }

    public static let identity = Mat4([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])

    public subscript(col: Int, row: Int) -> Float {
        get { m[col * 4 + row] }
        set { m[col * 4 + row] = newValue }
    }

    // MARK: - Projection

    /// Perspective projection in the **OpenGL/Three.js** convention, where
    /// clip-space z maps to [-1, 1]. This is what the fixtures capture, so it
    /// is the version tested for parity with the shipping renderer.
    ///
    /// `fovDegrees` is the *vertical* field of view, matching
    /// `THREE.PerspectiveCamera`.
    public static func perspectiveGL(fovDegrees: Float, aspect: Float,
                                     near: Float, far: Float) -> Mat4 {
        // Three.js: top = near * tan(½ fov); height = 2·top; width = aspect·height
        let top = near * tanf(Float.pi / 180 * 0.5 * fovDegrees)
        let height = 2 * top
        let width = aspect * height
        let x = 2 * near / width          // = 2·near / (right − left)
        let y = 2 * near / height         // = 2·near / (top − bottom)
        let c = -(far + near) / (far - near)
        let d = -2 * far * near / (far - near)
        // left/right and top/bottom are symmetric, so the skew terms are zero.
        return Mat4([ x, 0, 0, 0,
                      0, y, 0, 0,
                      0, 0, c, -1,
                      0, 0, d, 0 ])
    }

    /// Perspective projection in the **Metal** convention, where clip-space z
    /// maps to [0, 1]. Same framing as `perspectiveGL`, different depth range —
    /// this is the one the Metal renderer uploads.
    public static func perspectiveMetal(fovDegrees: Float, aspect: Float,
                                        near: Float, far: Float) -> Mat4 {
        let top = near * tanf(Float.pi / 180 * 0.5 * fovDegrees)
        let height = 2 * top
        let width = aspect * height
        let x = 2 * near / width
        let y = 2 * near / height
        let c = far / (near - far)
        let d = far * near / (near - far)
        return Mat4([ x, 0, 0, 0,
                      0, y, 0, 0,
                      0, 0, c, -1,
                      0, 0, d, 0 ])
    }

    // MARK: - Rotation

    /// Rotation matrix for Euler angles applied in Three.js **YXZ** order —
    /// the order the game's camera uses (`camera.rotation.order = 'YXZ'`), so
    /// yaw turns the head, pitch nods it, and roll banks the camcorder.
    public static func rotationYXZ(pitch: Float, yaw: Float, roll: Float) -> Mat4 {
        let a = cosf(pitch), b = sinf(pitch)
        let c = cosf(yaw),   d = sinf(yaw)
        let e = cosf(roll),  f = sinf(roll)
        let ce = c * e, cf = c * f, de = d * e, df = d * f
        // Rows of the 3×3 basis (written into column-major storage).
        let m00 = ce + df * b, m01 = de * b - cf, m02 = a * d
        let m10 = a * f,       m11 = a * e,       m12 = -b
        let m20 = cf * b - de, m21 = df + ce * b, m22 = a * c
        return Mat4([ m00, m10, m20, 0,
                      m01, m11, m21, 0,
                      m02, m12, m22, 0,
                      0,   0,   0,   1 ])
    }

    // MARK: - View

    /// The inverse of a camera's world transform: rotate by YXZ, translate to
    /// `position`, then invert. Because the transform is rigid (no scale) the
    /// inverse is just the transposed basis with a re-projected translation,
    /// which avoids a general matrix inversion.
    public static func view(positionX px: Float, y py: Float, z pz: Float,
                            pitch: Float, yaw: Float, roll: Float) -> Mat4 {
        let r = rotationYXZ(pitch: pitch, yaw: yaw, roll: roll)
        var out = [Float](repeating: 0, count: 16)
        out[15] = 1

        // Rotation block is Rᵀ: V_ij = R_ji. Storage is [col, row], so element
        // (row i, col j) of the view lands where element (row j, col i) of R
        // came from. Doing this with explicit indices rather than named
        // t00/t01/… avoids quietly reading a column where a row was meant —
        // which is exactly the bug this replaces.
        for i in 0..<3 {
            for j in 0..<3 {
                out[j * 4 + i] = r[i, j]
            }
        }
        // Translation is −Rᵀ·p, i.e. the camera position projected onto the
        // camera's own axes: V_i3 = −(R_0i·px + R_1i·py + R_2i·pz).
        for i in 0..<3 {
            out[12 + i] = -(r[i, 0] * px + r[i, 1] * py + r[i, 2] * pz)
        }
        return Mat4(out)
    }

    // MARK: - Ops

    /// Matrix product, `self · rhs` (column-vector convention, as in Three.js
    /// and Metal: a point is transformed as `M · p`).
    public func multiplied(by rhs: Mat4) -> Mat4 {
        var out = [Float](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<4 {
                var s: Float = 0
                for k in 0..<4 { s += self[k, row] * rhs[col, k] }
                out[col * 4 + row] = s
            }
        }
        return Mat4(out)
    }
}
