// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
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
        .package(url: "https://github.com/groue/Semaphore.git", from: "0.1.0"),
        .package(url: "https://github.com/photon-hq/SignozSwift.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .target(
            name: "AstrolabeUtils"
        ),
        .macro(
            name: "AstrolabeMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Astrolabe",
            dependencies: [
                "AstrolabeUtils",
                "AstrolabeMacros",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Semaphore", package: "Semaphore"),
                .product(name: "SignozSwift", package: "SignozSwift"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .testTarget(
            name: "AstrolabeTests",
            dependencies: ["Astrolabe", "AstrolabeUtils"]
        ),
        .testTarget(
            name: "AstrolabeMacrosTests",
            dependencies: [
                "AstrolabeMacros",
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ]
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
