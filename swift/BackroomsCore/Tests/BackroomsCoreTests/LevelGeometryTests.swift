import XCTest
@testable import BackroomsCore

/// Geometry fixtures hold per-chunk vertex counts and FNV-1a-64 hashes of the
/// Float32 buffers produced by the web game's own builder functions, plus its
/// collider buckets. Matching them proves the Swift emitters produce the
/// byte-identical vertex data the JS renderer uploads.
final class LevelGeometryTests: XCTestCase {

    struct GeoFixture: Decodable {
        let level: Int
        let grid: Int
        let chunkOut: [Chunk?]
        let colliders: [String: [[Double]]]
        struct Chunk: Decodable { let v: Int; let p: String; let n: String; let u: String }
    }

    private func loadFixture(_ level: Int) throws -> GeoFixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/geometry\(level)", withExtension: "json"))
        return try JSONDecoder().decode(GeoFixture.self, from: Data(contentsOf: url))
    }

    func testWallGeometryMatchesTheWebBuildByteForByte() throws {
        for level in 0..<4 {
            let fix = try loadFixture(level)
            let spec = LevelSpec.standardLevels[level]
            let map = GameMap.generate(spec: spec, levelIndex: level)
            let geo = LevelGeometry.build(map: map)

            XCTAssertEqual(geo.wallChunks.count, fix.chunkOut.count, "level \(level) chunk count")
            for (ci, expected) in fix.chunkOut.enumerated() {
                let mine = ci < geo.wallChunks.count ? geo.wallChunks[ci] : nil
                guard let expected else {
                    XCTAssertNil(mine, "level \(level) chunk \(ci) should be empty")
                    continue
                }
                let chunk = try XCTUnwrap(mine, "level \(level) chunk \(ci) missing")
                XCTAssertEqual(chunk.vertexCount, expected.v, "level \(level) chunk \(ci) verts")
                XCTAssertEqual(Fnv64.hash(floats: chunk.positions), expected.p, "level \(level) chunk \(ci) positions")
                XCTAssertEqual(Fnv64.hash(floats: chunk.normals), expected.n, "level \(level) chunk \(ci) normals")
                XCTAssertEqual(Fnv64.hash(floats: chunk.uvs), expected.u, "level \(level) chunk \(ci) uvs")
            }
        }
    }

    func testColliderBucketsMatchTheWebBuildExactly() throws {
        for level in 0..<4 {
            let fix = try loadFixture(level)
            let spec = LevelSpec.standardLevels[level]
            let map = GameMap.generate(spec: spec, levelIndex: level)
            let geo = LevelGeometry.build(map: map)

            XCTAssertEqual(geo.colliderBuckets.count, fix.colliders.count, "level \(level) bucket count")
            for (key, rects) in fix.colliders {
                let mine = geo.colliderBuckets[Int(key)!] ?? []
                XCTAssertEqual(mine.count, rects.count, "level \(level) bucket \(key) size")
                for (a, b) in zip(mine, rects) {
                    XCTAssertEqual(a.x0, b[0]); XCTAssertEqual(a.z0, b[1])
                    XCTAssertEqual(a.x1, b[2]); XCTAssertEqual(a.z1, b[3])
                }
            }
        }
    }
}
