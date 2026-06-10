// swift-tools-version: 6.2
// Standalone benchmark package: kept out of the library manifest so consumers
// of FPBracket never resolve or build the benchmark harness.

import PackageDescription

let package = Package(
    name: "fp-swift-bracket-benchmarks",
    // ContinuousClock needs macOS 13; the library itself stays at 10.15.
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "FPBracketBenchmarks",
            dependencies: [
                .product(name: "FPBracket", package: "fp-swift-bracket")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
