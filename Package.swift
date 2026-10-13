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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/photon-hq/SignozSwift.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AstrolabeUtils"
        ),
        .target(
            name: "Astrolabe",
            dependencies: [
                "AstrolabeUtils",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SignozSwift", package: "SignozSwift"),
                .product(name: "Subprocess", package: "swift-subprocess"),
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
            name: "StagingEngine",
            dependencies: ["Astrolabe"],
            path: "Examples/StagingEngine"
        ),
    ]
)
