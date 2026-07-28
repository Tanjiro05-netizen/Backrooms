import Foundation

/// Tiling value noise — the port of `makeNoise` in the web build.
///
/// A `period × period` grid of `mulberry32` samples, wrapped and interpolated
/// with the smoothstep curve `t²(3−2t)`. Because the lattice wraps, every
/// texture built on it tiles seamlessly, which is what lets one 512px sheet
/// cover a whole floor without a visible repeat seam.
public struct ValueNoise: Sendable {
    private let period: Int
    private let grid: [Double]

    public init(seed: UInt32, period: Int) {
        self.period = period
        var rng = Mulberry32(seed: seed)
        var g = [Double](repeating: 0, count: period * period)
        for i in 0..<g.count { g[i] = rng.nextUnit() }
        self.grid = g
    }

    @inline(__always)
    private func at(_ x: Int, _ y: Int) -> Double {
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
