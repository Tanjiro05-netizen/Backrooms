// swift-tools-version: 5.9
import PackageDescription

// Pure-Swift game core for the native Backrooms port, plus the Metal renderer
// that consumes it.
//
// `BackroomsCore` is deterministic and unit-tested against fixtures dumped
// from the shipping JS game, so the native world is provably the same world.
// `BackroomsRender` depends on it, never the reverse — which keeps the
// simulation testable on any machine, GPU or not.
let package = Package(
    name: "BackroomsCore",
    // Declared rather than left to default: SwiftPM otherwise assumes macOS
    // 10.13 for `swift test`, and the audio host needs AVAudioSourceNode
    // (10.15 / iOS 13). The app target deploys to iOS 17, so this floor only
    // has to be low enough not to fight it and high enough to compile.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BackroomsCore", targets: ["BackroomsCore"]),
        .library(name: "BackroomsRender", targets: ["BackroomsRender"])
    ],
    targets: [
        .target(name: "BackroomsCore"),
        .target(
            name: "BackroomsRender",
            dependencies: ["BackroomsCore"],
            // Shipped as a resource and compiled at runtime rather than
            // pre-built into a metallib, so plain `swift build` works
            // everywhere and CI can verify this target without an app.
            resources: [.copy("Shaders.metal")]
        ),
        .testTarget(
            name: "BackroomsCoreTests",
            dependencies: ["BackroomsCore", "BackroomsRender"],
            resources: [.copy("Fixtures")]
        )
    ]
)
