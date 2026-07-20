import Foundation

/// FNV-1a 64-bit — used to fingerprint vertex buffers so geometry fixtures
/// from the JS game can assert byte-identical output without shipping
/// megabytes of floats. Hashes the little-endian bytes of `[Float]`, which
/// is exactly what a JS `Float32Array` buffer contains.
public enum Fnv64 {
    public static func hash(bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    public static func hash(floats: [Float]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(floats.count * 4)
        for f in floats {
            let bits = f.bitPattern.littleEndian
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return String(hash(bytes: bytes), radix: 16)
    }
}
