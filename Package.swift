// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ms-notes",
    platforms: [.macOS("27.0")],
    targets: [
        // All logic lives here, testable headless.
        .target(name: "MsNotesCore", path: "Sources/MsNotesCore"),
        // Thin SwiftUI shell.
        .executableTarget(
            name: "MsNotesApp",
            dependencies: ["MsNotesCore"],
            path: "Sources/MsNotesApp"
        ),
        .testTarget(
            name: "MsNotesCoreTests",
            dependencies: ["MsNotesCore"],
            path: "Tests/MsNotesCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
