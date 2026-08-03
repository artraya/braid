// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "braid",
    // macOS 26, not 27: the newest Xcode on the App Store (26.6) ships the 26.5
    // SDK, and MLX needs Xcode for its Metal shaders. Braid uses nothing newer
    // than 26.0 anyway — FoundationModels and SpeechTranscriber both arrived
    // there — so this widens what can build it rather than giving anything up.
    platforms: [.macOS("26.0")],
    dependencies: [
        // Local ASR (Parakeet TDT v3) and offline diarization (pyannote
        // community-1), CoreML on the Neural Engine. Pinned exactly: it is
        // pre-1.0 and vendors a binary xcframework. ADR-0005 records why this
        // reverses ADR-0004's zero-dependency policy, and the way back out.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        // Open-weights summarisation, because Apple's on-device model refuses
        // whole subjects and no setting reaches that (ADR-0006). Pinned exactly
        // for the same reasons as FluidAudio, and more so: this one pulls a
        // dependency tree of its own and needs Xcode's Metal compiler, which is
        // why ADR-0004's no-Xcode decision was reversed to allow it.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", exact: "2.29.1"),
    ],
    targets: [
        // All logic lives here, testable headless.
        .target(
            name: "BraidCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/BraidCore"
        ),
        // The MLX summariser, kept out of BraidCore so the heavy dependency
        // sits at the edge: BraidCore stays buildable and testable without it.
        .target(
            name: "BraidMLX",
            dependencies: [
                "BraidCore",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ],
            path: "Sources/BraidMLX"
        ),
        // Thin SwiftUI shell.
        .executableTarget(
            name: "BraidApp",
            dependencies: ["BraidCore", "BraidMLX"],
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
