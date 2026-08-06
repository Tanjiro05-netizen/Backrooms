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
public struct TextureCanvas {
    public let size: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes per pixel.
    public private(set) var pixels: [UInt8]

    public init(size: Int, height: Int? = nil) {
        let rows = height ?? size
        self.size = size
        self.height = rows
        self.pixels = [UInt8](repeating: 255, count: size * rows * 4)
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
        let i = (yi * size + xi) * 4
        let inv = 1 - a
        pixels[i] = TextureCanvas.clamp8(r * a + Double(pixels[i]) * inv)
        pixels[i + 1] = TextureCanvas.clamp8(g * a + Double(pixels[i + 1]) * inv)
        pixels[i + 2] = TextureCanvas.clamp8(b * a + Double(pixels[i + 2]) * inv)
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
