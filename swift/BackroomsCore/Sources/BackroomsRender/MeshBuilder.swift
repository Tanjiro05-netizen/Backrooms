import Foundation

/// Accumulates interleaved world-space vertices.
///
/// The level shader takes no model matrix — level geometry is authored in world
/// space — so anything that moves or gets rebuilt (the entity, tapes, the exit
/// door) is emitted already transformed. This is the shared emitter for all of
/// them: one place that knows the winding, the normal rotation and the vertex
/// layout.
///
/// Alongside `addBox` there are round emitters — cylinder, sphere, capsule,
/// torus — because a room lit by Cook-Torrance and shaded by SSAO has nothing
/// to occlude if everything in it is an axis-aligned box. They all follow the
/// same convention as `addBox`: authored around a local origin, rotated by
/// `yaw` about Y, translated into world space, outward normals, counter-
/// clockwise winding seen from outside.
public struct MeshBuilder {
    public private(set) var vertices: [Float] = []

    public init(reservingBoxes count: Int = 0) {
        vertices.reserveCapacity(count * 36 * InterleavedMesh.floatsPerVertex)
    }

    /// For callers that mix round emitters in, where "boxes" is a bad unit.
    public init(reservingVertices count: Int) {
        vertices.reserveCapacity(count * InterleavedMesh.floatsPerVertex)
    }

    /// The six faces of a unit cube, wound counter-clockwise when seen from
    /// outside, with the outward normal and a corner sign per vertex.
    private static let faces: [(n: (Float, Float, Float), corners: [(Float, Float, Float)])] = [
        ((0, 0, 1),  [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
        ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
        ((1, 0, 0),  [(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, -1, 1), (1, 1, -1), (1, 1, 1)]),
        ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, -1, -1), (-1, 1, 1), (-1, 1, -1)]),
        ((0, 1, 0),  [(-1, 1, 1), (1, 1, 1), (1, 1, -1), (-1, 1, 1), (1, 1, -1), (-1, 1, -1)]),
        ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, -1), (1, -1, 1), (-1, -1, 1)])
    ]

    /// Vertices per box, so callers can assert what they emitted.
    public static let verticesPerBox = 36

    /// Adds a box whose centre is `local` in a frame rotated by `yaw` about Y
    /// and then translated to `origin`. `yaw` follows the camera convention:
    /// 0 faces −Z.
    public mutating func addBox(originX: Float, originY: Float, originZ: Float,
                                yaw: Float,
                                localX: Float, localY: Float, localZ: Float,
                                halfX: Float, halfY: Float, halfZ: Float,
                                u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1) {
        let c = cosf(yaw), s = sinf(yaw)
        for face in MeshBuilder.faces {
            let nx = face.n.0 * c + face.n.2 * s
            let nz = -face.n.0 * s + face.n.2 * c
            for corner in face.corners {
                let lx = localX + corner.0 * halfX
                let ly = localY + corner.1 * halfY
                let lz = localZ + corner.2 * halfZ
                let wx = originX + (lx * c + lz * s)
                let wz = originZ + (-lx * s + lz * c)
                let u = u0 + (corner.0 + 1) * 0.5 * (u1 - u0)
                let v = v0 + (corner.1 + 1) * 0.5 * (v1 - v0)
                vertices.append(contentsOf: [wx, originY + ly, wz, nx, face.n.1, nz, u, v])
            }
        }
    }

    public var isEmpty: Bool { vertices.isEmpty }
    public var mesh: InterleavedMesh { InterleavedMesh(rawVertices: vertices) }
    /// What this builder has cost so far, in triangles.
    public var triangleCount: Int { vertices.count / (InterleavedMesh.floatsPerVertex * 3) }

    // MARK: - Round emitters

    /// Which world axis a round emitter's length runs along, before `yaw`.
    ///
    /// Pipes run flat along a wall and lamp cords hang; a general orientation
    /// would mean carrying a full basis into every call site for three cases
    /// that are all anybody ever asks for.
    public enum Axis: Sendable { case x, y, z }

    /// A yaw-rotated, translated frame — the same one `addBox` applies inline.
    private struct Frame {
        let ox: Float, oy: Float, oz: Float, c: Float, s: Float
        init(_ ox: Float, _ oy: Float, _ oz: Float, yaw: Float) {
            self.ox = ox; self.oy = oy; self.oz = oz
            self.c = cosf(yaw); self.s = sinf(yaw)
        }
        func point(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
            (ox + (x * c + z * s), oy + y, oz + (-x * s + z * c))
        }
        /// Directions rotate but do not translate. The frame is a pure rotation
        /// about Y, so this is also the correct normal transform — no inverse
        /// transpose needed.
        func direction(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
            (x * c + z * s, y, -x * s + z * c)
        }
    }

    /// Canonical → local. Round shapes are built with their length along `a`
    /// and their cross-section in `(u, v)`; this permutes that triple onto the
    /// requested axis.
    ///
    /// Both non-identity cases are *cyclic* permutations on purpose: an
    /// odd permutation mirrors the shape, which would flip every triangle's
    /// winding and make the whole thing vanish under a back-face cull.
    private static func mapAxis(_ axis: Axis, _ u: Float, _ a: Float, _ v: Float)
        -> (Float, Float, Float) {
        switch axis {
        case .y: return (u, a, v)
        case .x: return (a, v, u)
        case .z: return (v, u, a)
        }
    }

    private static func normalized(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        let len = (x * x + y * y + z * z).squareRoot()
        guard len > 1e-9 else { return (0, 1, 0) }
        return (x / len, y / len, z / len)
    }

    private mutating func push(_ p: (Float, Float, Float), _ n: (Float, Float, Float),
                               _ u: Float, _ v: Float) {
        vertices.append(contentsOf: [p.0, p.1, p.2, n.0, n.1, n.2, u, v])
    }

    // MARK: Cylinder

    /// Vertices a cylinder of this description will add.
    public static func verticesPerCylinder(segments: Int, capped: Bool) -> Int {
        let n = max(3, segments)
        return n * 6 + (capped ? n * 6 : 0)
    }

    /// A cylinder centred on `local`, its length running along `axis` for
    /// `halfLength` either way. `capped` closes both ends; leave it off for
    /// pipe runs that butt into the next segment, which halves the cost.
    public mutating func addCylinder(originX: Float, originY: Float, originZ: Float,
                                     yaw: Float = 0,
                                     localX: Float, localY: Float, localZ: Float,
                                     radius: Float, halfLength: Float,
                                     axis: Axis = .y,
                                     segments: Int = 10,
                                     capped: Bool = true,
                                     uRepeat: Float = 1, vRepeat: Float = 1) {
        let n = max(3, segments)
        let frame = Frame(originX, originY, originZ, yaw: yaw)
        appendTube(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                   radius: radius, halfLength: halfLength, segments: n,
                   uRepeat: uRepeat, vRepeat: vRepeat)
        guard capped else { return }
        appendDisc(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                   radius: radius, offset: halfLength, facingPositive: true, segments: n)
        appendDisc(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                   radius: radius, offset: -halfLength, facingPositive: false, segments: n)
    }

    /// The open side wall. Wound (low, high, high+1) / (low, high+1, low+1),
    /// which puts the face normal outward for a right-handed cross product —
    /// the same test `addBox`'s +Z face passes.
    private mutating func appendTube(frame: Frame, axis: Axis,
                                     cx: Float, cy: Float, cz: Float,
                                     radius: Float, halfLength: Float,
                                     segments: Int, uRepeat: Float, vRepeat: Float) {
        for i in 0..<segments {
            let f0 = Float(i) / Float(segments)
            let f1 = Float(i + 1) / Float(segments)
            let a0 = f0 * 2 * Float.pi, a1 = f1 * 2 * Float.pi
            let c0 = cosf(a0), s0 = sinf(a0), c1 = cosf(a1), s1 = sinf(a1)

            let nc0 = MeshBuilder.mapAxis(axis, c0, 0, s0)
            let nc1 = MeshBuilder.mapAxis(axis, c1, 0, s1)
            let n0 = frame.direction(nc0.0, nc0.1, nc0.2)
            let n1 = frame.direction(nc1.0, nc1.1, nc1.2)

            func rim(_ c: Float, _ s: Float, _ along: Float) -> (Float, Float, Float) {
                let p = MeshBuilder.mapAxis(axis, c * radius, along, s * radius)
                return frame.point(cx + p.0, cy + p.1, cz + p.2)
            }
            let low0 = rim(c0, s0, -halfLength), high0 = rim(c0, s0, halfLength)
            let low1 = rim(c1, s1, -halfLength), high1 = rim(c1, s1, halfLength)
            let u0 = f0 * uRepeat, u1 = f1 * uRepeat

            push(low0, n0, u0, 0)
            push(high0, n0, u0, vRepeat)
            push(high1, n1, u1, vRepeat)
            push(low0, n0, u0, 0)
            push(high1, n1, u1, vRepeat)
            push(low1, n1, u1, 0)
        }
    }

    /// One end cap, as a fan from the centre. The two ends face opposite ways,
    /// so they wind opposite ways.
    private mutating func appendDisc(frame: Frame, axis: Axis,
                                     cx: Float, cy: Float, cz: Float,
                                     radius: Float, offset: Float,
                                     facingPositive: Bool, segments: Int) {
        let nc = MeshBuilder.mapAxis(axis, 0, facingPositive ? 1 : -1, 0)
        let normal = frame.direction(nc.0, nc.1, nc.2)
        let cc = MeshBuilder.mapAxis(axis, 0, offset, 0)
        let centre = frame.point(cx + cc.0, cy + cc.1, cz + cc.2)

        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * Float.pi
            let a1 = Float(i + 1) / Float(segments) * 2 * Float.pi
            let c0 = cosf(a0), s0 = sinf(a0), c1 = cosf(a1), s1 = sinf(a1)
            func rim(_ c: Float, _ s: Float) -> (Float, Float, Float) {
                let p = MeshBuilder.mapAxis(axis, c * radius, offset, s * radius)
                return frame.point(cx + p.0, cy + p.1, cz + p.2)
            }
            let p0 = rim(c0, s0), p1 = rim(c1, s1)
            push(centre, normal, 0.5, 0.5)
            if facingPositive {
                push(p1, normal, 0.5 + 0.5 * c1, 0.5 + 0.5 * s1)
                push(p0, normal, 0.5 + 0.5 * c0, 0.5 + 0.5 * s0)
            } else {
                push(p0, normal, 0.5 + 0.5 * c0, 0.5 + 0.5 * s0)
                push(p1, normal, 0.5 + 0.5 * c1, 0.5 + 0.5 * s1)
            }
        }
    }

    // MARK: Sphere

    /// Vertices a full UV sphere will add. The two polar rings are fans, not
    /// quads, so they cost half.
    public static func verticesPerSphere(segments: Int, rings: Int) -> Int {
        let n = max(3, segments), r = max(2, rings)
        return n * (6 * (r - 2) + 3 * 2)
    }

    /// A UV sphere (or a spheroid, when `heightRadius` differs) centred on
    /// `local`. `heightRadius` measures along `axis`.
    public mutating func addSphere(originX: Float, originY: Float, originZ: Float,
                                   yaw: Float = 0,
                                   localX: Float, localY: Float, localZ: Float,
                                   radius: Float, heightRadius: Float? = nil,
                                   axis: Axis = .y,
                                   segments: Int = 12, rings: Int = 8) {
        let frame = Frame(originX, originY, originZ, yaw: yaw)
        appendLatitudeBand(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                           radial: radius, along: heightRadius ?? radius, alongOffset: 0,
                           phi0: -Float.pi / 2, phi1: Float.pi / 2,
                           segments: max(3, segments), rings: max(2, rings))
    }

    /// Half a sphere, open at the equator — a lamp shade or a pool light.
    /// `pointingUp` puts the closed end toward +`axis`.
    public mutating func addHemisphere(originX: Float, originY: Float, originZ: Float,
                                       yaw: Float = 0,
                                       localX: Float, localY: Float, localZ: Float,
                                       radius: Float, heightRadius: Float? = nil,
                                       axis: Axis = .y, pointingUp: Bool = true,
                                       segments: Int = 12, rings: Int = 4) {
        let frame = Frame(originX, originY, originZ, yaw: yaw)
        appendLatitudeBand(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                           radial: radius, along: heightRadius ?? radius, alongOffset: 0,
                           phi0: pointingUp ? 0 : -Float.pi / 2,
                           phi1: pointingUp ? Float.pi / 2 : 0,
                           segments: max(3, segments), rings: max(1, rings))
    }

    /// A band of latitude, from `phi0` to `phi1` (−π/2 is the −axis pole).
    /// Triangles that would be degenerate at a pole are skipped rather than
    /// emitted zero-area, which is both cheaper and keeps every normal finite.
    private mutating func appendLatitudeBand(frame: Frame, axis: Axis,
                                             cx: Float, cy: Float, cz: Float,
                                             radial: Float, along: Float,
                                             alongOffset: Float,
                                             phi0: Float, phi1: Float,
                                             segments: Int, rings: Int) {
        let rr = max(1e-5, radial), ra = max(1e-5, along)
        for j in 0..<rings {
            let g0 = Float(j) / Float(rings), g1 = Float(j + 1) / Float(rings)
            let p0 = phi0 + (phi1 - phi0) * g0
            let p1 = phi0 + (phi1 - phi0) * g1
            let cp0 = cosf(p0), sp0 = sinf(p0), cp1 = cosf(p1), sp1 = sinf(p1)
            let lowPole = abs(cp0) < 1e-5, highPole = abs(cp1) < 1e-5

            for i in 0..<segments {
                let f0 = Float(i) / Float(segments), f1 = Float(i + 1) / Float(segments)
                let a0 = f0 * 2 * Float.pi, a1 = f1 * 2 * Float.pi
                let ca0 = cosf(a0), sa0 = sinf(a0), ca1 = cosf(a1), sa1 = sinf(a1)

                func at(_ cp: Float, _ sp: Float, _ ca: Float, _ sa: Float)
                    -> ((Float, Float, Float), (Float, Float, Float)) {
                    let lp = MeshBuilder.mapAxis(axis, rr * cp * ca, ra * sp + alongOffset,
                                                 rr * cp * sa)
                    let world = frame.point(cx + lp.0, cy + lp.1, cz + lp.2)
                    // Gradient of the spheroid, which is the true normal when
                    // the two radii differ.
                    let raw = MeshBuilder.normalized(cp * ca / rr, sp / ra, cp * sa / rr)
                    let mapped = MeshBuilder.mapAxis(axis, raw.0, raw.1, raw.2)
                    return (world, frame.direction(mapped.0, mapped.1, mapped.2))
                }

                let a = at(cp0, sp0, ca0, sa0)
                let b = at(cp1, sp1, ca0, sa0)
                let c = at(cp1, sp1, ca1, sa1)
                let d = at(cp0, sp0, ca1, sa1)

                if !highPole {
                    push(a.0, a.1, f0, g0)
                    push(b.0, b.1, f0, g1)
                    push(c.0, c.1, f1, g1)
                }
                if !lowPole {
                    push(a.0, a.1, f0, g0)
                    push(c.0, c.1, f1, g1)
                    push(d.0, d.1, f1, g0)
                }
            }
        }
    }

    // MARK: Capsule

    /// Vertices a capsule will add: an open tube plus two hemispherical ends.
    public static func verticesPerCapsule(segments: Int, rings: Int) -> Int {
        let n = max(3, segments), r = max(1, rings)
        // One hemisphere is a latitude band whose last (or first) ring is a fan.
        let hemisphere = n * (6 * (r - 1) + 3)
        return n * 6 + hemisphere * 2
    }

    /// A capsule: a cylinder of half-length `halfLength` with a hemisphere on
    /// each end, so the whole thing is `2 * (halfLength + radius)` long.
    /// Handrails and limbs — anything that should not show a flat disc when you
    /// look at its end.
    public mutating func addCapsule(originX: Float, originY: Float, originZ: Float,
                                    yaw: Float = 0,
                                    localX: Float, localY: Float, localZ: Float,
                                    radius: Float, halfLength: Float,
                                    axis: Axis = .y,
                                    segments: Int = 10, rings: Int = 3) {
        let n = max(3, segments), r = max(1, rings)
        let frame = Frame(originX, originY, originZ, yaw: yaw)
        appendTube(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                   radius: radius, halfLength: halfLength, segments: n,
                   uRepeat: 1, vRepeat: 1)
        appendLatitudeBand(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                           radial: radius, along: radius, alongOffset: halfLength,
                           phi0: 0, phi1: Float.pi / 2, segments: n, rings: r)
        appendLatitudeBand(frame: frame, axis: axis, cx: localX, cy: localY, cz: localZ,
                           radial: radius, along: radius, alongOffset: -halfLength,
                           phi0: -Float.pi / 2, phi1: 0, segments: n, rings: r)
    }

    // MARK: Capsule between two points

    private static func cross(_ ax: Float, _ ay: Float, _ az: Float,
                              _ bx: Float, _ by: Float, _ bz: Float) -> (Float, Float, Float) {
        (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
    }

    /// A capsule spanning two world-space points, at any angle.
    ///
    /// Everything else here is authored around a yaw-only frame, which cannot
    /// tilt — and a limb that leans has to actually lean. Displacing an upright
    /// box along Z (which is how the stickman fakes a stride) reads as a leg
    /// sliding rather than swinging, and a bent knee is impossible. This builds
    /// its own basis from the segment direction instead.
    ///
    /// `radius` is the tube radius, so the whole capsule is `|B−A| + 2·radius`
    /// end to end.
    public mutating func addCapsuleBetween(ax: Float, ay: Float, az: Float,
                                           bx: Float, by: Float, bz: Float,
                                           radius: Float,
                                           segments: Int = 8, rings: Int = 2) {
        let n = max(3, segments), r = max(1, rings)
        var dx = bx - ax, dy = by - ay, dz = bz - az
        let length = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard length > 1e-5, radius > 1e-5 else { return }
        dx /= length; dy /= length; dz /= length

        // Any reference not parallel to the axis will do for the first tangent.
        let ux: Float, uy: Float, uz: Float
        if abs(dy) < 0.9 { ux = 0; uy = 1; uz = 0 } else { ux = 1; uy = 0; uz = 0 }
        // t1 = normalise(d × up), t2 = t1 × d. Taken in *that* order, the
        // triangles below come out facing away from the axis; the other order
        // faces them inward and the whole limb disappears under the cull.
        let raw = MeshBuilder.cross(dx, dy, dz, ux, uy, uz)
        let t1 = MeshBuilder.normalized(raw.0, raw.1, raw.2)
        let t2 = MeshBuilder.cross(t1.0, t1.1, t1.2, dx, dy, dz)

        func ring(_ c: Float, _ s: Float) -> (Float, Float, Float) {
            (t1.0 * c + t2.0 * s, t1.1 * c + t2.1 * s, t1.2 * c + t2.2 * s)
        }
        func along(_ base: (Float, Float, Float), _ nrm: (Float, Float, Float))
            -> (Float, Float, Float) {
            (base.0 + nrm.0 * radius, base.1 + nrm.1 * radius, base.2 + nrm.2 * radius)
        }

        let a = (ax, ay, az), b = (bx, by, bz)

        // The tube.
        for i in 0..<n {
            let f0 = Float(i) / Float(n), f1 = Float(i + 1) / Float(n)
            let a0 = f0 * 2 * Float.pi, a1 = f1 * 2 * Float.pi
            let n0 = ring(cosf(a0), sinf(a0)), n1 = ring(cosf(a1), sinf(a1))
            let low0 = along(a, n0), high0 = along(b, n0)
            let low1 = along(a, n1), high1 = along(b, n1)
            push(low0, n0, f0, 0)
            push(high0, n0, f0, 1)
            push(high1, n1, f1, 1)
            push(low0, n0, f0, 0)
            push(high1, n1, f1, 1)
            push(low1, n1, f1, 0)
        }

        /// One hemispherical end, as (unit normal, u, v) triples in triangle
        /// order. Every point of a hemisphere is its centre plus `radius` times
        /// its own normal, so the normals are all the caller needs.
        ///
        /// `w` is the outward axis. At the A end that is −d, which mirrors the
        /// parametrisation and so reverses the winding — hence `flip`.
        func capVertices(_ wx: Float, _ wy: Float, _ wz: Float, _ flip: Bool)
            -> [((Float, Float, Float), Float, Float)] {
            var out: [((Float, Float, Float), Float, Float)] = []
            out.reserveCapacity(n * 6)
            func at(_ cp: Float, _ sp: Float, _ ang: Float) -> (Float, Float, Float) {
                let rr = ring(cosf(ang), sinf(ang))
                return MeshBuilder.normalized(rr.0 * cp + wx * sp,
                                              rr.1 * cp + wy * sp,
                                              rr.2 * cp + wz * sp)
            }
            func tri(_ p: ((Float, Float, Float), Float, Float),
                     _ q: ((Float, Float, Float), Float, Float),
                     _ s: ((Float, Float, Float), Float, Float)) {
                let ordered: [((Float, Float, Float), Float, Float)] =
                    flip ? [s, q, p] : [p, q, s]
                out.append(contentsOf: ordered)
            }
            for j in 0..<r {
                let g0 = Float(j) / Float(r), g1 = Float(j + 1) / Float(r)
                let p0 = g0 * Float.pi / 2, p1 = g1 * Float.pi / 2
                let cp0 = cosf(p0), sp0 = sinf(p0), cp1 = cosf(p1), sp1 = sinf(p1)
                // The last ring closes on the pole, where one of the two
                // triangles would be zero-area.
                let pole = abs(cp1) < 1e-5
                for i in 0..<n {
                    let f0 = Float(i) / Float(n), f1 = Float(i + 1) / Float(n)
                    let a0 = f0 * 2 * Float.pi, a1 = f1 * 2 * Float.pi
                    let na = at(cp0, sp0, a0), nb = at(cp1, sp1, a0)
                    let nc = at(cp1, sp1, a1), nd = at(cp0, sp0, a1)
                    if !pole { tri((na, f0, g0), (nb, f0, g1), (nc, f1, g1)) }
                    tri((na, f0, g0), (nc, f1, g1), (nd, f1, g0))
                }
            }
            return out
        }

        for v in capVertices(dx, dy, dz, false) { push(along(b, v.0), v.0, v.1, v.2) }
        for v in capVertices(-dx, -dy, -dz, true) { push(along(a, v.0), v.0, v.1, v.2) }
    }

    // MARK: Torus

    /// Vertices a torus will add.
    public static func verticesPerTorus(majorSegments: Int, minorSegments: Int) -> Int {
        max(3, majorSegments) * max(3, minorSegments) * 6
    }

    /// A torus centred on `local`, its hole running along `axis`. Valve
    /// handwheels, pipe collars, the ring around a pool light.
    public mutating func addTorus(originX: Float, originY: Float, originZ: Float,
                                  yaw: Float = 0,
                                  localX: Float, localY: Float, localZ: Float,
                                  majorRadius: Float, minorRadius: Float,
                                  axis: Axis = .y,
                                  majorSegments: Int = 12, minorSegments: Int = 6) {
        let major = max(3, majorSegments), minor = max(3, minorSegments)
        let frame = Frame(originX, originY, originZ, yaw: yaw)

        for j in 0..<minor {
            let g0 = Float(j) / Float(minor), g1 = Float(j + 1) / Float(minor)
            let p0 = g0 * 2 * Float.pi, p1 = g1 * 2 * Float.pi
            let cp0 = cosf(p0), sp0 = sinf(p0), cp1 = cosf(p1), sp1 = sinf(p1)

            for i in 0..<major {
                let f0 = Float(i) / Float(major), f1 = Float(i + 1) / Float(major)
                let a0 = f0 * 2 * Float.pi, a1 = f1 * 2 * Float.pi
                let ca0 = cosf(a0), sa0 = sinf(a0), ca1 = cosf(a1), sa1 = sinf(a1)

                func at(_ cp: Float, _ sp: Float, _ ca: Float, _ sa: Float)
                    -> ((Float, Float, Float), (Float, Float, Float)) {
                    let ring = majorRadius + minorRadius * cp
                    let lp = MeshBuilder.mapAxis(axis, ring * ca, minorRadius * sp, ring * sa)
                    let world = frame.point(localX + lp.0, localY + lp.1, localZ + lp.2)
                    let nn = MeshBuilder.mapAxis(axis, cp * ca, sp, cp * sa)
                    return (world, frame.direction(nn.0, nn.1, nn.2))
                }

                let a = at(cp0, sp0, ca0, sa0)
                let b = at(cp1, sp1, ca0, sa0)
                let c = at(cp1, sp1, ca1, sa1)
                let d = at(cp0, sp0, ca1, sa1)

                push(a.0, a.1, f0, g0)
                push(b.0, b.1, f0, g1)
                push(c.0, c.1, f1, g1)
                push(a.0, a.1, f0, g0)
                push(c.0, c.1, f1, g1)
                push(d.0, d.1, f1, g0)
            }
        }
    }
}
