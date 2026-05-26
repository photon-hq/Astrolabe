// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Astrolabe",
    platforms: [.macOS(.v15)],
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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/photon-hq/SignozSwift.git", from: "0.2.4"),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SignozSwift", package: "SignozSwift"),
            ]
        ),
        .testTarget(
            name: "AstrolabeTests",
            dependencies: ["Astrolabe", "AstrolabeUtils"]
        ),
        .executableTarget(
            name: "StorageClientWriter",
            dependencies: ["AstrolabeUtils"],
            path: "Tests/StorageClientWriter"
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
        .executableTarget(
            name: "SelfUpdating",
            dependencies: ["Astrolabe"],
            path: "Examples/SelfUpdating"
        ),
    ]
)
