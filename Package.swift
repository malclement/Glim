// swift-tools-version: 6.0
import PackageDescription

// Glim is built with SwiftPM alone; the Makefile assembles and signs the .app.
// There is deliberately no .xcodeproj: Xcode can open this file directly.
let package = Package(
    name: "Glim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Glim", targets: ["Glim"]),
        .library(name: "GlimCore", targets: ["GlimCore"]),
    ],
    targets: [
        // Hardware access, protocol and state. No AppKit or SwiftUI, so it is
        // testable without launching the app or owning a monitor.
        .target(
            name: "GlimCore",
            path: "Sources/GlimCore"
        ),
        // The menu bar app.
        .executableTarget(
            name: "Glim",
            dependencies: ["GlimCore"],
            path: "Sources/Glim"
        ),
        // Simulated displays and mocks shared by the test targets.
        .target(
            name: "GlimTestSupport",
            dependencies: ["GlimCore"],
            path: "Tests/GlimTestSupport"
        ),
        .testTarget(
            name: "GlimCoreTests",
            dependencies: ["GlimCore", "GlimTestSupport"],
            path: "Tests/GlimCoreTests",
            resources: [.copy("Fixtures")]
        ),
        // Renders the app's views against simulated monitors.
        .testTarget(
            name: "GlimAppTests",
            dependencies: ["Glim", "GlimCore", "GlimTestSupport"],
            path: "Tests/GlimAppTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
