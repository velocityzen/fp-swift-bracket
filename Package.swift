// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "fp-swift-bracket",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "FPBracket",
            targets: ["FPBracket"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/velocityzen/fp-swift", from: "2.1.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "FPBracket",
            dependencies: [
                .product(name: "FP", package: "fp-swift")
            ]
        ),
        .testTarget(
            name: "FPBracketTests",
            dependencies: ["FPBracket"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
