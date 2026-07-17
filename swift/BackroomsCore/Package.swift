// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift game core for the native Backrooms port. No UIKit, no Metal —
// every system in here is deterministic and unit-tested against fixtures
// dumped from the shipping JS game, so the native world is provably the
// same world. Rendering/input layers depend on this, never the reverse.
let package = Package(
    name: "BackroomsCore",
    products: [
        .library(name: "BackroomsCore", targets: ["BackroomsCore"])
    ],
    targets: [
        .target(name: "BackroomsCore"),
        .testTarget(
            name: "BackroomsCoreTests",
            dependencies: ["BackroomsCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
