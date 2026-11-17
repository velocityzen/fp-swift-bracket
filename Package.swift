// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "fp-swift-bracket",
    platforms: [
        .macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "FPBracket",
            targets: ["FPBracket"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/velocityzen/fp-swift", from: "4.7.0"),
        // Property-based tests. Test targets only, so FPBracket's users never
        // fetch it.
        .package(url: "https://github.com/velocityzen/hegel-swift", from: "0.51.8"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.`
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "FPBracket",
            dependencies: [
                .product(name: "FP", package: "fp-swift")
            ],
            swiftSettings: [
                // Async functions and closures run on the caller's actor, so
                // non-Sendable brackets can be called from @MainActor code.
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "FPBracketTests",
            dependencies: ["FPBracket"]
        ),
        // Hegel's engine is built for macOS and Linux only, so on the other
        // platforms this target is empty: every file is behind
        // `#if os(macOS) || os(Linux)`.
        .testTarget(
            name: "FPBracketPropertyTests",
            dependencies: [
                "FPBracket",
                .product(
                    name: "HegelTesting",
                    package: "hegel-swift",
                    condition: .when(platforms: [.macOS, .linux])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
