import Foundation

/// Tiling value noise — the port of `makeNoise` in the web build.
///
/// A `period × period` grid of `mulberry32` samples, wrapped and interpolated
/// with the smoothstep curve `t²(3−2t)`. Because the lattice wraps, every
/// texture built on it tiles seamlessly, which is what lets one 512px sheet
/// cover a whole floor without a visible repeat seam.
///
/// The one thing to keep in mind when calling it: the lattice wraps at
/// `period`, so a sheet only tiles if the coordinates handed in cross a whole
/// number of periods over one repeat. `fbm(u * 256, …)` on a period-256 field
/// tiles; `fbm(u * 200, …)` does not, and grows a seam.
public struct ValueNoise: Sendable {
    private let period: Int
    private let mask: Int
    private let powerOfTwo: Bool
    private let grid: [Double]

    public init(seed: UInt32, period: Int) {
        let p = max(1, period)
        self.period = p
        self.mask = p - 1
        self.powerOfTwo = (p & (p - 1)) == 0
        var rng = Mulberry32(seed: seed)
        var g = [Double](repeating: 0, count: p * p)
        for i in 0..<g.count { g[i] = rng.nextUnit() }
        self.grid = g
    }

    /// Lattice fetch with wrapping.
    ///
    /// Every period in this codebase is a power of two, and for those the wrap
    /// is a mask rather than the two integer divisions `((x % p) + p) % p`
    /// costs. That matters more than it looks: this is four calls per noise
    /// sample and several samples per texel across ten 512² sheets, so the
    /// divisions were a measurable slice of level-load time all by themselves.
    /// Two's complement makes `x & mask` agree with the modulo for negative x.
    @inline(__always)
    private func at(_ x: Int, _ y: Int) -> Double {
        if powerOfTwo {
            return grid[(y & mask) * period + (x & mask)]
        }
        let xi = ((x % period) + period) % period
        let yi = ((y % period) + period) % period
        return grid[yi * period + xi]
    }

    public func callAsFunction(_ x: Double, _ y: Double) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let xf = x - Double(xi), yf = y - Double(yi)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        return at(xi, yi) * (1 - u) * (1 - v)
            + at(xi + 1, yi) * u * (1 - v)
            + at(xi, yi + 1) * (1 - u) * v
            + at(xi + 1, yi + 1) * u * v
    }

    /// Fractal sum: `octaves` doublings of frequency at halving amplitude.
    /// Matches the web build's `fbm(n, x, y, o)` exactly, including the fact
    /// that the amplitudes sum to less than 1 (so output is not normalised).
    ///
    /// Note that every octave here reads the *same* lattice at a higher
    /// frequency, so the detail octaves are the base octave magnified and the
    /// pattern recurs at the lattice period. `FractalNoise` is the version that
    /// gives each octave its own lattice; prefer it for anything where the
    /// repetition would be visible.
    public func fbm(_ x: Double, _ y: Double, _ octaves: Int) -> Double {
        var a = 0.0, amp = 0.5, f = 1.0
        for _ in 0..<octaves {
            a += self(x * f, y * f) * amp
            amp *= 0.5
            f *= 2
        }
        return a
    }
}

/// A stack of tiling value-noise octaves, each on its own lattice.
///
/// This exists because `ValueNoise.fbm` reuses one grid for every octave: its
/// high frequencies are its low frequency magnified, so the "detail" recurs on
/// the lattice period and the eye picks that up as a grid. Here octave *i* gets
/// its own `ValueNoise` whose period *is* that octave's frequency, so the sum
/// is broadband — a 1/f spectrum from `base` cycles per repeat up to
/// `base · 2^(octaves−1)` — with nothing recognisable recurring inside a sheet.
/// Every octave still completes a whole number of cycles across the tile, so
/// the sum wraps and the sheets stay seamless.
///
/// Coordinates are in *tile space*: one repeat of the texture spans 0…1 on both
/// axes, which is what makes it safe to hand `u`,`v` straight in without having
/// to remember which multiplier keeps a given field seamless.
public struct FractalNoise: Sendable {
    private let layers: [ValueNoise]
    private let freqs: [Double]
    private let amps: [Double]
    private let norm: Double

    /// - Parameters:
    ///   - base: cycles across one repeat at the lowest octave. 2 gives slow
    ///     drift over the whole sheet; 128 gives near-texel grain on a 512 map.
    ///   - octaves: each one doubles frequency and multiplies amplitude by
    ///     `gain`. Going past `base · 2^(n−1) ≈ size/2` only buys aliasing.
    public init(seed: UInt32, base: Int, octaves: Int, gain: Double = 0.5) {
        var ls: [ValueNoise] = []
        var fs: [Double] = []
        var ws: [Double] = []
        var total = 0.0
        var p = max(1, base)
        var amp = 1.0
        let count = max(1, octaves)
        ls.reserveCapacity(count)
        fs.reserveCapacity(count)
        ws.reserveCapacity(count)
        for i in 0..<count {
            let octaveSeed = seed &+ (UInt32(truncatingIfNeeded: i) &* 7919) &+ 13
            ls.append(ValueNoise(seed: octaveSeed, period: p))
            fs.append(Double(p))
            ws.append(amp)
            total += amp
            p *= 2
            amp *= gain
        }
        self.layers = ls
        self.freqs = fs
        self.amps = ws
        self.norm = total > 0 ? total : 1
    }

    /// The field in [0,1], normalised — unlike `fbm`, which deliberately is not.
    public func callAsFunction(_ u: Double, _ v: Double) -> Double {
        var s = 0.0
        for i in 0..<layers.count {
            let f = freqs[i]
            s += layers[i](u * f, v * f) * amps[i]
        }
        return s / norm
    }

    /// The same field remapped to [−1,1], which is the form most of the
    /// material loops want: something to add to a base colour without also
    /// shifting its mean.
    public func signed(_ u: Double, _ v: Double) -> Double {
        return callAsFunction(u, v) * 2 - 1
    }

    /// Ridged variant — `1 − |2n−1|` per octave, which turns the smooth blobs
    /// inside out into creases. This is the shape of a fissure in mineral
    /// board, a craze line in glaze, or a trowel arc in a concrete slab; none
    /// of those are blobby, and faking them with thresholded smooth noise gives
    /// wobbly sausages instead of lines.
    public func ridged(_ u: Double, _ v: Double) -> Double {
        var s = 0.0
        for i in 0..<layers.count {
            let f = freqs[i]
            let n = layers[i](u * f, v * f)
            s += (1 - abs(n * 2 - 1)) * amps[i]
        }
        return s / norm
    }

    /// Directionally squashed sample, for materials with a grain: carpet pile,
    /// brushed metal, trowel direction.
    ///
    /// `xRepeat`/`yRepeat` multiply the lattice frequency on that axis, so
    /// `stretched(u, v, xRepeat: 4, yRepeat: 1)` makes features four times
    /// narrower across than along. They must be whole numbers — a fractional
    /// one stops the octave completing an integer number of cycles across the
    /// tile, and the sheet grows a seam.
    public func stretched(_ u: Double, _ v: Double, xRepeat: Int, yRepeat: Int) -> Double {
        let kx = Double(max(1, xRepeat))
        let ky = Double(max(1, yRepeat))
        var s = 0.0
        for i in 0..<layers.count {
            let f = freqs[i]
            s += layers[i](u * f * kx, v * f * ky) * amps[i]
        }
        return s / norm
    }
}

/// Deterministic integer hash, for per-cell variation.
///
/// Tiled materials — ceiling panels, pool tile, the snap-tie lattice in a
/// concrete pour — need a handful of independent random numbers *per cell*.
/// A noise lattice is the wrong tool (it interpolates, and cells want hard
/// edges) and a precomputed table has to be sized to the cell count up front.
/// A hash of the cell index costs neither.
public enum ProceduralHash {
    /// A value in [0,1) from a pair of integers and a salt. Same inputs, same
    /// output, on every platform — it is all wrapping 32-bit integer math.
    public static func unit(_ x: Int, _ y: Int, _ salt: UInt32) -> Double {
        var h: UInt32 = salt &* 0x9E37_79B9
        h = h ^ (UInt32(truncatingIfNeeded: x) &* 0x85EB_CA6B)
        h = (h ^ (h >> 13)) &* 0xC2B2_AE35
        h = h ^ (UInt32(truncatingIfNeeded: y) &* 0x27D4_EB2F)
        h = (h ^ (h >> 16)) &* 0x1656_67B1
        h = h ^ (h >> 15)
        return Double(h) / 4294967296.0
    }

    /// The same value centred on zero, in [−0.5, 0.5).
    public static func signed(_ x: Int, _ y: Int, _ salt: UInt32) -> Double {
        return unit(x, y, salt) - 0.5
    }
}
