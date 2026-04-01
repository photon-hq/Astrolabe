// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Astrolabe",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "Astrolabe",
            targets: ["Astrolabe"]
        ),
        .library(
            name: "AstrolabeUtils",
            targets: ["AstrolabeUtils"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/Semaphore.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "AstrolabeUtils"
        ),
        .target(
            name: "Astrolabe",
            dependencies: [
                "AstrolabeUtils",
                .product(name: "Semaphore", package: "Semaphore"),
            ]
        ),
        .testTarget(
            name: "AstrolabeTests",
            dependencies: ["Astrolabe"]
        ),

        // MARK: - Examples

        .executableTarget(
            name: "BasicSetup",
            dependencies: ["Astrolabe"],
            path: "Examples/BasicSetup"
        ),
        .executableTarget(
            name: "ConditionalSetup",
            dependencies: ["Astrolabe"],
            path: "Examples/ConditionalSetup"
        ),
        .executableTarget(
            name: "GroupModifiers",
            dependencies: ["Astrolabe"],
            path: "Examples/GroupModifiers"
        ),
    ]
)
