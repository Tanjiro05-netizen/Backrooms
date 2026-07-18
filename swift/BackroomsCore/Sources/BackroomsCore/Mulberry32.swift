/// Bit-exact port of the JS game's `mulberry32` PRNG.
///
/// The web build seeds every level with `mulberry32(SEED + level * 7919)` and
/// draws all map decisions from it, so reproducing the stream exactly is what
/// makes the native port walk the *same corridors*. All arithmetic is 32-bit
/// wrapping, matching JS `|0` / `Math.imul` / `>>>` semantics; the division by
/// 2^32 is exact in Double, so downstream `floor(rng * n)` math is identical.
public struct Mulberry32: RandomNumberGenerator {
    private var state: UInt32

    public init(seed: UInt32) {
        self.state = seed
    }

    /// Next value in [0, 1) — the direct equivalent of the JS closure call.
    public mutating func nextUnit() -> Double {
        state = state &+ 0x6D2B79F5
        var t: UInt32 = (state ^ (state >> 15)) &* (state | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }

    /// `Math.floor(rng() * n)` as used throughout map generation.
    public mutating func nextInt(_ n: Int) -> Int {
        Int((nextUnit() * Double(n)).rounded(.down))
    }

    // RandomNumberGenerator conformance (not used by the port's hot paths,
    // but lets Swift API accept this generator directly).
    public mutating func next() -> UInt64 {
        state = state &+ 0x6D2B79F5
        var t: UInt32 = (state ^ (state >> 15)) &* (state | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        let hi = UInt64(t ^ (t >> 14))
        state = state &+ 0x6D2B79F5
        var u: UInt32 = (state ^ (state >> 15)) &* (state | 1)
        u = (u &+ ((u ^ (u >> 7)) &* (u | 61))) ^ u
        return (hi << 32) | UInt64(u ^ (u >> 14))
    }
}
