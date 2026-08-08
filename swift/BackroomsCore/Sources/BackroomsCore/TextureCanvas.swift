import Foundation

/// A CPU RGBA8 raster with the handful of drawing operations the texture
/// generators need.
///
/// The web build synthesises every surface into a `<canvas>`: a per-pixel loop
/// for the base material, then a few Canvas2D passes on top for stains, cracks
/// and rust drips. The per-pixel loops port across exactly. The overlay passes
/// are reimplemented here as direct rasterisation rather than replaying
/// Canvas2D semantics — gradient coordinate spaces under a transform are
/// fiddly enough that matching the *intent* (an elliptical falloff centred on
/// the stain) is more honest than matching a canvas quirk. So: the base
/// material is a port, the grime on top is a reimplementation.
///
/// Everything wraps at the edges, because these textures tile.
///
/// One addition the port did not have: every overlay also records its coverage
/// into a wear mask (see `takeWear`). Grime that only exists in the albedo is
/// the single loudest tell that a surface was generated — a crack with no depth
/// and a puddle with the same gloss as the dry floor beside it. The mask lets a
/// generator push the same coverage into its height and roughness fields.
public struct TextureCanvas {
    public let size: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes per pixel.
    public private(set) var pixels: [UInt8]
    /// Peak overlay coverage per texel since the last `takeWear()`.
    private var wear: [Float]

    public init(size: Int, height: Int? = nil) {
        let rows = height ?? size
        self.size = size
        self.height = rows
        self.pixels = [UInt8](repeating: 255, count: size * rows * 4)
        self.wear = [Float](repeating: 0, count: size * rows)
    }

    @inline(__always)
    static func clamp8(_ v: Double) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v.rounded())
    }

    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, r: Double, g: Double, b: Double) {
        let i = (y * size + x) * 4
        pixels[i] = TextureCanvas.clamp8(r)
        pixels[i + 1] = TextureCanvas.clamp8(g)
        pixels[i + 2] = TextureCanvas.clamp8(b)
        pixels[i + 3] = 255
    }

    /// Source-over blend of a straight (non-premultiplied) colour.
    @inline(__always)
    mutating func blend(_ x: Int, _ y: Int, r: Double, g: Double, b: Double, a: Double) {
        guard a > 0 else { return }
        let xi = ((x % size) + size) % size
        let yi = ((y % height) + height) % height
        let m = yi * size + xi
        let i = m * 4
        let inv = 1 - a
        pixels[i] = TextureCanvas.clamp8(r * a + Double(pixels[i]) * inv)
        pixels[i + 1] = TextureCanvas.clamp8(g * a + Double(pixels[i + 1]) * inv)
        pixels[i + 2] = TextureCanvas.clamp8(b * a + Double(pixels[i + 2]) * inv)
        let cov = Float(a)
        if cov > wear[m] { wear[m] = cov }
    }

    /// Hands back the coverage the overlay passes have laid down since the last
    /// call, and starts a fresh mask.
    ///
    /// Generators run their grime in groups and take the mask after each group,
    /// because the polarity differs: soot dulls a wall, a water stain leaves a
    /// mineral crust that dulls it further, a scuff on a painted baseboard
    /// polishes it, standing water makes it a mirror. One global mask could not
    /// express that; a mask per group can.
    public mutating func takeWear() -> [Float] {
        let taken = wear
        wear = [Float](repeating: 0, count: size * height)
        return taken
    }

    // MARK: - Overlay passes

    /// A soft elliptical smear: opaque within the inner 15% of the radius, then
    /// falling linearly to nothing at the rim, rotated by `rotation` and
    /// squashed to `aspect` on its minor axis.
    public mutating func stain(x cx: Double, y cy: Double, radius: Double,
                               aspect: Double, rotation: Double,
                               r: Double, g: Double, b: Double, alpha: Double) {
        let cosR = cos(-rotation), sinR = sin(-rotation)
        // The ellipse's device-space extent, so we only touch pixels near it.
        let reach = Int(ceil(radius * max(1, aspect))) + 2
        let x0 = Int(cx.rounded(.down)) - reach, x1 = Int(cx.rounded(.down)) + reach
        let y0 = Int(cy.rounded(.down)) - reach, y1 = Int(cy.rounded(.down)) + reach
        guard radius > 0, aspect > 0 else { return }

        for py in y0...y1 {
            for px in x0...x1 {
                let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                // Into the ellipse's own frame, then undo the minor-axis squash.
                let lx = dx * cosR - dy * sinR
                let ly = (dx * sinR + dy * cosR) / aspect
                let d = (lx * lx + ly * ly).squareRoot()
                guard d < radius else { continue }
                let inner = radius * 0.15
                let t = d <= inner ? 0 : (d - inner) / (radius - inner)
                blend(px, py, r: r, g: g, b: b, a: alpha * (1 - t))
            }
        }
    }

    /// `stain` with its rim chewed up by noise.
    ///
    /// Nothing in a damp building has a clean elliptical edge. Mould advances
    /// in fingers, a water stain dries in a ragged tide line, rust creeps along
    /// whatever it can wet. A perfect ellipse is the giveaway; `wobble` (0…1)
    /// is how far the boundary is allowed to wander in and out.
    public mutating func blot(x cx: Double, y cy: Double, radius: Double,
                              aspect: Double, rotation: Double, wobble: Double,
                              noise: ValueNoise,
                              r: Double, g: Double, b: Double, alpha: Double) {
        guard radius > 0, aspect > 0 else { return }
        let w = min(max(wobble, 0), 1)
        let cosR = cos(-rotation), sinR = sin(-rotation)
        let reach = Int(ceil(radius * max(1, aspect) * (1 + w))) + 2
        let cxi = Int(cx.rounded(.down)), cyi = Int(cy.rounded(.down))
        for py in (cyi - reach)...(cyi + reach) {
            for px in (cxi - reach)...(cxi + reach) {
                let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                let lx = dx * cosR - dy * sinR
                let ly = (dx * sinR + dy * cosR) / aspect
                let d = (lx * lx + ly * ly).squareRoot()
                let n = noise(Double(px) * 0.07, Double(py) * 0.07)
                let rr = radius * (1 - w * 0.5 + w * n)
                guard rr > 0, d < rr else { continue }
                let t = d / rr
                let fall = (1 - t) * (1 - t)
                blend(px, py, r: r, g: g, b: b, a: alpha * fall)
            }
        }
    }

    /// A wandering hairline — the `cracks` pass. Each crack is a random walk of
    /// short segments, which reads as a settling crack rather than a scratch.
    public mutating func cracks(count: Int, seed: UInt32,
                                r: Double, g: Double, b: Double, alpha: Double,
                                maxWidth: Double) {
        var rng = Mulberry32(seed: seed)
        for _ in 0..<count {
            var x = rng.nextUnit() * Double(size)
            var y = rng.nextUnit() * Double(height)
            var angle = rng.nextUnit() * 6.28
            let width = 0.6 + rng.nextUnit() * maxWidth
            let steps = 8 + Int(rng.nextUnit() * 14)
            for _ in 0..<steps {
                angle += (rng.nextUnit() - 0.5) * 1.3
                let nx = x + cos(angle) * (4 + rng.nextUnit() * 10)
                let ny = y + sin(angle) * (4 + rng.nextUnit() * 10)
                line(x0: x, y0: y, x1: nx, y1: ny, width: width,
                     r: r, g: g, b: b, alpha: alpha)
                x = nx; y = ny
            }
        }
    }

    /// A soft-edged streak between two points, fading across its width and
    /// along its length — abrasion rather than a drawn stroke.
    ///
    /// This is what a shoe leaves on a baseboard, a pallet leaves on a slab and
    /// a hand leaves on tile. `cracks` draws hard-edged hairlines because a
    /// crack really does have an edge; a scuff does not.
    public mutating func smear(x0: Double, y0: Double, x1: Double, y1: Double,
                               width: Double,
                               r: Double, g: Double, b: Double, alpha: Double) {
        let half = max(0.5, width / 2)
        let minX = Int((min(x0, x1) - half).rounded(.down)) - 1
        let maxX = Int((max(x0, x1) + half).rounded(.up)) + 1
        let minY = Int((min(y0, y1) - half).rounded(.down)) - 1
        let maxY = Int((max(y0, y1) + half).rounded(.up)) + 1
        let dx = x1 - x0, dy = y1 - y0
        let lenSq = max(1e-9, dx * dx + dy * dy)
        for py in minY...maxY {
            for px in minX...maxX {
                let pxC = Double(px) + 0.5, pyC = Double(py) + 0.5
                var t = ((pxC - x0) * dx + (pyC - y0) * dy) / lenSq
                if t < 0 { t = 0 } else if t > 1 { t = 1 }
                let qx = x0 + dx * t, qy = y0 + dy * t
                let ex = pxC - qx, ey = pyC - qy
                let d = (ex * ex + ey * ey).squareRoot()
                guard d <= half else { continue }
                let across = 1 - d / half
                let along = 1 - t * 0.8
                blend(px, py, r: r, g: g, b: b, a: alpha * across * across * along)
            }
        }
    }

    /// Scattered dots — grit on a floor, air voids in a concrete pour, the
    /// punched pinholes in an acoustic ceiling panel.
    public mutating func specks(count: Int, seed: UInt32,
                                minRadius: Double, maxRadius: Double,
                                r: Double, g: Double, b: Double, alpha: Double) {
        guard count > 0, maxRadius > 0 else { return }
        var rng = Mulberry32(seed: seed)
        let span = max(0, maxRadius - minRadius)
        for _ in 0..<count {
            let cx = rng.nextUnit() * Double(size)
            let cy = rng.nextUnit() * Double(height)
            let rad = max(0.4, minRadius + rng.nextUnit() * span)
            let a = alpha * (0.45 + rng.nextUnit() * 0.55)
            let reach = Int(ceil(rad)) + 1
            let cxi = Int(cx.rounded(.down)), cyi = Int(cy.rounded(.down))
            for py in (cyi - reach)...(cyi + reach) {
                for px in (cxi - reach)...(cxi + reach) {
                    let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                    let d = (dx * dx + dy * dy).squareRoot()
                    guard d <= rad else { continue }
                    blend(px, py, r: r, g: g, b: b, a: a)
                }
            }
        }
    }

    /// A vertical streak fading downward — rust and water running down a wall.
    public mutating func drip(x cx: Double, top: Double, length: Double, width: Double,
                              r: Double, g: Double, b: Double, alpha: Double) {
        let half = width / 2
        let x0 = Int((cx - half).rounded(.down)), x1 = Int((cx + half).rounded(.up))
        let y0 = Int(top.rounded(.down)), y1 = Int((top + length).rounded(.up))
        guard length > 0 else { return }
        for py in y0...y1 {
            let t = (Double(py) + 0.5 - top) / length
            guard t >= 0, t <= 1 else { continue }
            for px in x0...x1 {
                blend(px, py, r: r, g: g, b: b, a: alpha * (1 - t))
            }
        }
    }

    /// `drip` with a path and a profile.
    ///
    /// Water does not run down a wall in a straight bar of constant width. It
    /// tracks, it is heaviest where it started, and it narrows as it is used
    /// up. `wander` is how far it is allowed to stray sideways; the streak also
    /// falls off across its width instead of ending in two hard columns.
    public mutating func runoff(x cx: Double, top: Double, length: Double, width: Double,
                                wander: Double, seed: UInt32,
                                r: Double, g: Double, b: Double, alpha: Double) {
        guard length > 0, width > 0 else { return }
        var rng = Mulberry32(seed: seed)
        let half = max(0.5, width / 2)
        let steps = Int(length.rounded(.up))
        var drift = 0.0
        for i in 0..<steps {
            let t = min(1.0, Double(i) / length)
            drift = drift * 0.94 + (rng.nextUnit() - 0.5) * 0.2 * wander
            let x = cx + drift
            let py = Int((top + Double(i)).rounded(.down))
            let w = half * (0.55 + 0.75 * (1 - t))
            let a = alpha * (1 - t) * (0.65 + 0.35 * (1 - t))
            guard a > 0, w > 0 else { continue }
            let x0 = Int((x - w).rounded(.down)), x1 = Int((x + w).rounded(.up))
            for px in x0...x1 {
                let d = abs(Double(px) + 0.5 - x)
                guard d <= w else { continue }
                blend(px, py, r: r, g: g, b: b, a: a * (1 - d / w))
            }
        }
    }

    /// A stroked circle — the water rings on stained ceiling tiles.
    public mutating func ring(x cx: Double, y cy: Double, radius: Double, width: Double,
                              r: Double, g: Double, b: Double, alpha: Double) {
        let outer = radius + width / 2, inner = max(0, radius - width / 2)
        let reach = Int(ceil(outer)) + 1
        for py in (Int(cy) - reach)...(Int(cy) + reach) {
            for px in (Int(cx) - reach)...(Int(cx) + reach) {
                let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                let d = (dx * dx + dy * dy).squareRoot()
                guard d >= inner, d <= outer else { continue }
                blend(px, py, r: r, g: g, b: b, a: alpha)
            }
        }
    }

    /// `ring` with a boundary that wanders, for the tide lines a leak dries
    /// into. A perfect circle on a ceiling tile reads as a decal.
    public mutating func waterRing(x cx: Double, y cy: Double, radius: Double,
                                   width: Double, wobble: Double, noise: ValueNoise,
                                   r: Double, g: Double, b: Double, alpha: Double) {
        guard radius > 0, width > 0 else { return }
        let w = min(max(wobble, 0), 1)
        let reach = Int(ceil(radius * (1 + w) + width)) + 2
        let cxi = Int(cx.rounded(.down)), cyi = Int(cy.rounded(.down))
        for py in (cyi - reach)...(cyi + reach) {
            for px in (cxi - reach)...(cxi + reach) {
                let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                let d = (dx * dx + dy * dy).squareRoot()
                let n = noise(Double(px) * 0.05, Double(py) * 0.05)
                let rr = radius * (1 - w * 0.5 + w * n)
                let off = abs(d - rr)
                guard off <= width else { continue }
                let a = alpha * (1 - off / width)
                blend(px, py, r: r, g: g, b: b, a: a)
            }
        }
    }

    /// Anti-aliasing-free thick segment, drawn by distance-to-segment so the
    /// joins between crack steps do not leave gaps.
    private mutating func line(x0: Double, y0: Double, x1: Double, y1: Double,
                               width: Double, r: Double, g: Double, b: Double, alpha: Double) {
        let half = width / 2
        let minX = Int(min(x0, x1) - half) - 1, maxX = Int(max(x0, x1) + half) + 1
        let minY = Int(min(y0, y1) - half) - 1, maxY = Int(max(y0, y1) + half) + 1
        let dx = x1 - x0, dy = y1 - y0
        let lenSq = max(1e-9, dx * dx + dy * dy)
        for py in minY...maxY {
            for px in minX...maxX {
                let pxC = Double(px) + 0.5, pyC = Double(py) + 0.5
                var t = ((pxC - x0) * dx + (pyC - y0) * dy) / lenSq
                t = max(0, min(1, t))
                let qx = x0 + dx * t, qy = y0 + dy * t
                let d = ((pxC - qx) * (pxC - qx) + (pyC - qy) * (pyC - qy)).squareRoot()
                guard d <= half else { continue }
                blend(px, py, r: r, g: g, b: b, a: alpha)
            }
        }
    }
}

/// Derives a tangent-space normal map from a height field, matching the web
/// build's `normalFromHeight`: central differences, wrapped, with `nz = 2`.
///
/// The height fields feeding this are in **texel units**: a height difference
/// of 1.0 between neighbouring texels is a 45° facet before `strength` is
/// applied (the central difference over ±1 texel is 2.0, which equals `nz`).
/// Keeping every generator on that one scale is what stops a grout step
/// authored in "colour units" from laying the normal flat on its side — which
/// is what a 40-unit step through a 1.5 strength used to do. `strength` above 1
/// is then a deliberate, readable exaggeration rather than a magic number.
public func normalMap(from heights: [Float], size: Int, strength: Double) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let xl = Double(heights[y * size + ((x - 1 + size) % size)])
            let xr = Double(heights[y * size + ((x + 1) % size)])
            let yu = Double(heights[((y - 1 + size) % size) * size + x])
            let yd = Double(heights[((y + 1) % size) * size + x])
            let nx = (xl - xr) * strength
            let ny = (yu - yd) * strength
            let nz = 2.0
            let l = (nx * nx + ny * ny + nz * nz).squareRoot()
            let i = (y * size + x) * 4
            out[i] = TextureCanvas.clamp8((nx / l * 0.5 + 0.5) * 255)
            out[i + 1] = TextureCanvas.clamp8((ny / l * 0.5 + 0.5) * 255)
            out[i + 2] = TextureCanvas.clamp8((nz / l * 0.5 + 0.5) * 255)
            out[i + 3] = 255
        }
    }
    return out
}
