// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Astrolabe",
    platforms: [.macOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Astrolabe",
            targets: ["Astrolabe"]
        ),
    ],
    targets: [
        .target(
            name: "Astrolabe"
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
