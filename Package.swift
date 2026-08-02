// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "braid",
    platforms: [.macOS("27.0")],
    dependencies: [
        // Local ASR (Parakeet TDT v3) and offline diarization (pyannote
        // community-1), CoreML on the Neural Engine. Pinned exactly: it is
        // pre-1.0 and vendors a binary xcframework. ADR-0005 records why this
        // reverses ADR-0004's zero-dependency policy, and the way back out.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        // All logic lives here, testable headless.
        .target(
            name: "BraidCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/BraidCore"
        ),
        // Thin SwiftUI shell.
        .executableTarget(
            name: "BraidApp",
            dependencies: ["BraidCore"],
            path: "Sources/BraidApp"
        ),
        .testTarget(
            name: "BraidCoreTests",
            dependencies: ["BraidCore"],
            path: "Tests/BraidCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
