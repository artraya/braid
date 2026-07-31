// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "braid",
    platforms: [.macOS("27.0")],
    targets: [
        // All logic lives here, testable headless.
        .target(name: "BraidCore", path: "Sources/BraidCore"),
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
