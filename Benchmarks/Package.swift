// swift-tools-version: 6.3
// Standalone benchmark package: kept out of the library manifest so consumers
// of FPBracket never resolve or build the benchmark harness.

import PackageDescription

let package = Package(
    name: "fp-swift-bracket-benchmarks",
    // Matches the library's minimum, which follows fp-swift.
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "FPBracketBenchmarks",
            dependencies: [
                .product(name: "FPBracket", package: "fp-swift-bracket")
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
